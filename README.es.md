[English version](README.md)

# Un puente Docker-a-host para acelerar ffmpeg por hardware en Android

Jellyfin corre muy bien en Docker en casi cualquier cosa — excepto cuando el único codificador
de video por hardware disponible está detrás de un ABI al que el contenedor no puede llegar en
absoluto. Eso es exactamente lo que pasa en Android: la codificación por hardware está ahí
mismo, en el mismo kernel que el contenedor, y aun así un Jellyfin-en-Docker completamente
normal no tiene forma de tocarla, sin importar cómo se compile ffmpeg. Este es el puente de tres
piezas que resuelve eso, sin sacar a Jellyfin de Docker en ningún momento.

Desarrollado y validado en un teléfono reutilizado como pequeño servidor de medios en casa — un
dispositivo Android con un SoC Exynos, corriendo la carga en Termux — pero nada de esto es
específico de ese chip. Cualquier dispositivo Android que exponga codificación por hardware vía
`AMediaCodec` a través de Termux debería funcionar igual.

## El problema

En Android, la codificación/decodificación de video por hardware se expone a través de
`AMediaCodec`, parte del NDK de Android, implementado en `libmediandk.so`. Esa librería está
compilada contra **bionic**, el libc de Android. Un contenedor Docker normal — Debian, Alpine,
lo que sea — corre un userland compilado contra **glibc** o **musl**. Un binario enlazado contra
glibc/musl no puede hacer `dlopen()` de un `.so` de bionic, punto, sin importar quién lo haya
compilado ni con qué flags. Un ffmpeg compilado con `--enable-mediacodec` dentro de un contenedor
Docker normal no tiene, por lo tanto, ninguna forma de llegar al codificador de hardware que está
ahí mismo, en el mismo kernel.

La única forma de llegar de verdad a `AMediaCodec` es correr un userland real de Android/Termux
(bionic) directamente en el dispositivo, fuera de Docker. Lo que lleva a la pregunta obvia:
¿significa eso que Jellyfin mismo tiene que salir de Docker?

**No.** Jellyfin es un servidor .NET sin ninguna dependencia de ABI con Android — solo invoca a
`ffmpeg` como proceso externo vía una línea de comandos y una ruta de binario configurada. El
desajuste de ABI es enteramente una propiedad del *binario de ffmpeg*, no de Jellyfin. Así que
Jellyfin puede quedarse exactamente donde está — mismo contenedor, misma configuración, mismas
librerías, todo igual — y solo lo que hace de "ffmpeg" necesita cambiar.

## El diseño

Tres piezas:

1. **`bridge-client.pl`** (dentro del contenedor) — un script pequeño al que apuntas el flag
   `--ffmpeg` de Jellyfin en vez de a un binario real de ffmpeg. Desde el punto de vista de
   Jellyfin, esto *es* ffmpeg: recibe los mismos argumentos, transmite stdout/stderr en vivo, y
   sale con el mismo código que produciría un proceso real de ffmpeg. Escrito en Perl
   específicamente porque la mayoría de imágenes de contenedor mínimas ya traen los módulos
   básicos `IO::Socket`/`IO::Select` de Perl gratis, permitiendo que esto corra sin instalar
   ningún paquete extra en la imagen.
2. **`bridge-daemon.py`** (en el host real) — un demonio pequeño y persistente que escucha
   únicamente en la dirección de puerta de enlace/bridge de tu red de contenedores (nunca en tu
   LAN). Recibe un trabajo (una lista de argumentos) del cliente, traduce cualquier ruta interna
   del contenedor a la ruta real del host detrás de ese mismo bind mount, y lanza el wrapper como
   proceso hijo.
3. **`wrapper-ffmpeg.sh`** (en el host real) — reescribe únicamente el argumento del *codificador*
   (`-c:v libx264` → `-c:v h264_mediacodec`, y el equivalente para HEVC), quita un puñado de
   opciones que no tienen sentido para un codificador de hardware (`-preset`, `-crf`, etc.), y le
   pasa todo lo demás sin tocar a un build real de ffmpeg capaz de usar hardware.

Los archivos de entrada y salida viven en el mismo filesystem que el demonio ya puede ver (los
mismos bind mounts que usa tu contenedor, solo que vistos desde el host), así que lo único que
realmente cruza la frontera cliente/demonio es una lista corta de argumentos y un flujo de texto
en vivo de stdout/stderr — nunca los bytes del video en sí. Eso es lo que hace esto rápido y
simple: nunca se hace proxy de datos de video.

## Tres restricciones de diseño que importan si construyes sobre esto

No eran obvias al principio, y equivocarse en cualquiera de las tres produce síntomas que parecen
completamente ajenos a la causa real.

### 1. La decodificación siempre debe quedarse en software

Es tentador pasarle `-hwaccel mediacodec` también al *decodificador*, una vez que confirmas que el
lado de codificación funciona. No lo hagas. La decodificación por hardware vía `AMediaCodec`
espera un contexto real de app de Android — un `SurfaceTexture`/`ANativeWindow` respaldado por una
`Activity` real y una ventana compuesta por GPU. Un proceso sin interfaz gráfica (Termux, o
cualquier contenedor igual de headless) no tiene nada de eso. El resultado no es un error limpio —
es un cuelgue duro. La llamada al decodificador se bloquea indefinidamente e **ignora SIGTERM**;
solo SIGKILL realmente lo detiene. Esto es una limitación arquitectónica de la plataforma, no un
flag de compilación que se pueda arreglar — `--disable-decoder=h264_mediacodec` al compilar ffmpeg
es un resguardo real que vale la pena agregar, pero solo previene el error, no desbloquea nada.

El wrapper de arriba codifica esto como una regla dura: solo reescribe el *codificador* (`-c:v`),
y quita defensivamente cualquier `-hwaccel *mediacodec*` que vea al pasar, sin importar de dónde
haya salido. La decodificación siempre es la ruta normal por software. La codificación es el único
lugar donde se usa aceleración por hardware.

Los codificadores de hardware reales también rechazan o se cuelgan con algunas entradas
directamente (resolución, perfil, profundidad de bits, y demás pueden disparar esto) — no todo
archivo es compatible con el codificador de cada dispositivo. El wrapper maneja esto con una
espera acotada a que el archivo de salida del muxer realmente empiece a aparecer en disco: si no
aparece nada en una ventana corta de tiempo, mata el intento de hardware (SIGTERM, y luego SIGKILL
si lo ignora) y reintenta transparentemente con codificación por software pura — así que un
archivo incompatible degrada a velocidad de software, no a un stream roto.

### 2. El relevo de stdout/stderr debe ser no bloqueante, o bloquea todo

Esta parte es más sutil y de verdad hizo falta depuración en producción para encontrarla.

El script cliente (`bridge-client.pl`) necesita escribir el stdout y stderr de ffmpeg de vuelta a
*su propio* stdout/stderr, porque Jellyfin está observando esos flujos de la misma forma en que
observaría un proceso real de ffmpeg (principalmente stderr, para saber que la codificación está
avanzando y que el proceso no dejó de responder). La implementación ingenua simplemente hace
`print STDOUT $payload` y `print STDERR $payload` a medida que llegan datos.

Esa es una escritura bloqueante. Y aquí está la trampa: en un trabajo real de transcodificación de
Jellyfin, **Jellyfin nunca lee el stdout del proceso envuelto** — solo lee stderr. Si el script
cliente alguna vez escribe algo de tamaño considerable a stdout, no hay nadie del otro lado
drenando ese pipe. El buffer del sistema operativo se llena (típicamente 64KB en Linux) casi de
inmediato, y la siguiente llamada a `print STDOUT` se bloquea — no un momento, sino *para
siempre*, porque nadie va a leer nunca de ese pipe.

Una vez que esa escritura se bloquea, el loop principal del script cliente se detiene por
completo — no puede volver a leer más datos del socket del demonio. Eso retropresiona los envíos
del propio demonio, lo que retropresiona al proceso real de ffmpeg corriendo en el host (sus
propios pipes de stdout/stderr hacia el demonio se llenan después), y **todo** el pipeline se
congela. Desde afuera esto se ve exactamente como una transcodificación misteriosamente colgada:
el proceso real de ffmpeg sigue vivo, sigue quemando CPU con trabajo ya almacenado en buffer, pero
nunca se ve más progreso ni se entrega ninguna salida al cliente final — todo disparado por un
flujo de salida que nadie siquiera necesitaba en primer lugar.

La solución: hacer que tanto stdout como stderr en el lado del cliente sean **no bloqueantes**
(`fcntl(..., O_NONBLOCK)`), y enrutarlos a través de un pequeño buffer acotado en memoria por cada
flujo en vez de escribir directamente. Cada iteración del loop principal vacía oportunistamente lo
que puede sin bloquear; si un destino está lleno, la escritura simplemente no ocurre en esa
iteración — el loop que drena el socket nunca se detiene por eso, y si el buffer alguna vez se
llena, los datos más viejos se descartan silenciosamente en vez de crecer sin límite. Un lector
downstream lleno o completamente ausente ahora solo significa "no pasa nada", nunca "todo se
congela para siempre".

El invariante que hay que mantener, si estás construyendo algo similar: **un consumidor
downstream lento o totalmente ausente nunca debe poder bloquear tu proceso de seguir drenando su
entrada upstream.** Cualquier loop de relevo que viole esto está a un lector silencioso de un
bloqueo total.

### 3. Los scripts de arranque no heredan el `PATH` de tu shell interactiva — usa rutas absolutas

Esta costó tiempo real de servicio caído en rastrear, y el síntoma no apuntaba para nada hacia la
causa real.

Si corres el demonio (o su envoltorio de reinicio-al-caer) vía un mecanismo de arranque que escala
privilegios en un shell nuevo — un envoltorio `su`/`sudo`, una unidad de systemd con su propio
entorno mínimo, un script de init — ese shell **no** hereda el `PATH` que tiene tu sesión
interactiva normal. Un loop de reinicio que lanza el demonio con un `python3` pelado (confiando en
que se pueda resolver por `PATH`, cierto en cualquier shell interactiva desde la que lo pruebes)
va a fallar con "command not found" en cada arranque, aunque funcione perfecto cada vez que lo
corres a mano. El loop de reinicio entonces hace exactamente lo que está diseñado a hacer —
reintenta de inmediato, para siempre — lo que convierte un binario faltante en un bucle de caídas
apretado en vez de un error obvio de una sola línea.

La solución es mecánica: usa la ruta absoluta al intérprete (o binario) en cualquier cosa que un
script de arranque lance — `/ruta/a/python3`, no `python3`. No confíes en que el `PATH` esté
configurado igual que en el shell desde el que estás probando; los contextos de ejecución al
arrancar rutinariamente no lo están.

Un riesgo secundario relacionado, que vale la pena cubrir de todas formas: si el demonio y el
contenedor que depende de él arrancan ambos desde la misma secuencia de arranque, no hay ninguna
garantía inherente de que el demonio haya enlazado su socket de escucha antes de que la propia
verificación de capacidades de arranque del contenedor lo alcance. Hacer que el código de gestión
de contenedores espere, acotado, a que el puerto del demonio esté escuchando antes de un arranque
en frío es un seguro barato contra esa carrera, además de resolver bien el tema del `PATH`.

## Qué es realmente reutilizable acá vs. qué es específico de tu setup

El protocolo, el mecanismo de traducción de rutas, la lógica de detección de cuelgues, y el
arreglo del relevo no bloqueante son todos genéricos y deberían funcionar tal cual para cualquier
situación de "Jellyfin-en-Docker, codificador de hardware fuera del alcance del contenedor" — no
solo Android/mediacodec. Cambia los nombres de codificador en `wrapper-ffmpeg.sh` y esta misma
forma de tres piezas funciona igual para, por ejemplo, un nodo de dispositivo VAAPI que tu
contenedor no puede ver, o cualquier otra capacidad de hardware del lado del host que tu runtime
de contenedores no pueda pasar directamente.

Lo que necesitas completar para tu propio despliegue (todo vía variables de entorno, documentado
en línea en cada archivo — nada necesita editarse a mano en los scripts):

- `BRIDGE_BIND_ADDR` / `BRIDGE_PORT` — la dirección de puerta de enlace de tu red de contenedores
  y un puerto de tu elección.
- `BRIDGE_MEDIA_HOST_PATH` / `BRIDGE_CONFIG_HOST_PATH` / `BRIDGE_CACHE_HOST_PATH` — las rutas
  reales del host detrás de los bind mounts `/media`, `/config`, y `/cache` de tu contenedor
  (agrega más entradas a `PATH_MAP` en `bridge-daemon.py` si tienes montajes adicionales).
- `BRIDGE_WRAPPER_PATH` / `REAL_FFMPEG` — dónde viven realmente el script wrapper y tu binario de
  ffmpeg real capaz de usar hardware, en el host.

## Boceto de instalación

1. En el host (Termux u otro), instala un build de ffmpeg con soporte de mediacodec por hardware
   compilado, y coloca `wrapper-ffmpeg.sh` + `bridge-daemon.py` en algún lugar de él.
2. Configura las variables de entorno de arriba para que coincidan con tus rutas de bind mount
   reales y tu red de contenedores, y luego corre `bridge-daemon.py` como proceso de larga
   duración (un simple loop de reinicio-al-caer alrededor de él es un seguro barato).
3. Empaqueta `bridge-client.pl` en la imagen de tu contenedor de Jellyfin (o móntalo como bind
   mount), y apunta el flag de arranque `--ffmpeg` de Jellyfin (o la variable de entorno
   equivalente para tu despliegue) a él en vez del binario real de ffmpeg.
4. Reinicia el contenedor. Jellyfin ahora transcodifica a través del codificador de hardware de tu
   host — con una caída automática y transparente a software para todo lo que el hardware no
   pueda manejar.
