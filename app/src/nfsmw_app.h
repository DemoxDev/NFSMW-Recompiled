// nfsmw - ReXGlue Recompiled Project
//
// Customize your app by overriding virtual hooks from rex::ReXApp.

#pragma once

#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/logging.h>
#include <rex/rex_app.h>
#include <rex/ui/overlay/debug_overlay.h>
#include <rex/ui/presenter.h>  // CONTADOR DE FPS - fotogramas del juego
#include <rex/system/kernel_state.h>  // VIGILANTE DE CUELGUES
#include <rex/system/xthread.h>       // VIGILANTE DE CUELGUES

#include <algorithm>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <map>  // VIGILANTE DE CUELGUES - la firma se ordena por id de hilo
#include <memory>
#include <string>
#include <thread>
#include <vector>

// Fallos de pagina de la memoria vigilada de la GPU. Es LA cifra que queda
// por bajar: cada uno sigue costando ~1.100 ciclos. Definidos en el SDK,
// src/system/xmemory.cpp.
extern "C" std::atomic<uint64_t> g_violaciones_totales;
extern "C" std::atomic<uint64_t> g_violaciones_fisicas;

class NfsmwApp : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<NfsmwApp>(new NfsmwApp(ctx, "nfsmw",
        PPCImageConfig));
  }

  // Ganchos disponibles y sin usar:
  //   void OnPreSetup(rex::RuntimeConfig& config) override {}
  //   void OnLoadXexImage(std::string& xex_image) override {}
  //   void OnPostLoadXexImage() override {}
  //   void OnCreateDialogs(rex::ui::ImGuiDrawer* drawer) override {}
  //   void OnShutdown() override {}
  //
  // Los tres de abajo SI estan usados: rutas portables, ajustes obligatorios
  // y contador de fps.

 protected:
  // ==========================================================================
  //  1. RUTAS PORTABLES: encontrar la ISO al lado del .exe
  //
  //  Sin esto, arrancar sin --game_data_root muere con
  //      "--game_data_root was not provided."
  //  porque SetupEnvironment solo mira el cvar y, si esta vacio,
  //  ConstructRuntime aborta.
  //
  //  OnConfigurePaths se llama justo despues de construir el PathConfig y
  //  antes de que nadie lo use, asi que es el sitio para rellenar el hueco.
  //
  //  ORDEN, QUE IMPORTA: esto corre ANTES de que se cargue nfsmw.toml -el SDK
  //  lo lee unas lineas mas abajo, en SetupEnvironment-. Asi que la prioridad
  //  real es: --game_data_root de la linea de comandos, y si no, lo que se
  //  encuentre aqui al lado. Poner game_data_root en el toml NO funciona, y
  //  no es cosa nuestra: es como esta ordenado el SDK.
  //
  //  Se busca, en este orden:
  //    1. un .iso cuyo nombre coincida con el del ejecutable
  //    2. cualquier otro .iso de la carpeta, por orden alfabetico
  //    3. una carpeta game_root\, por si alguien prefiere extraerla
  //
  //  El (1) existe para que una carpeta con NFS_Most_Wanted.exe y
  //  NFS_Most_Wanted.iso funcione sin ambiguedad aunque haya mas imagenes.
  // ==========================================================================
  void OnConfigurePaths(rex::PathConfig& paths) override {
    if (!paths.game_data_root.empty()) {
      return;  // el usuario lo dijo por linea de comandos; manda el.
    }

    std::error_code ec;
    const auto carpeta = rex::filesystem::GetExecutableFolder();
    if (carpeta.empty() || !std::filesystem::is_directory(carpeta, ec)) {
      return;
    }

    // El nombre del ejecutable, para el caso preferente.
    std::filesystem::path preferida;
    std::vector<std::filesystem::path> otras;

    std::string yo;
    {
      const auto exe = rex::filesystem::GetExecutablePath();
      if (!exe.empty()) {
        yo = exe.stem().string();
        std::transform(yo.begin(), yo.end(), yo.begin(),
                       [](unsigned char c) { return char(std::tolower(c)); });
      }
    }

    for (const auto& e : std::filesystem::directory_iterator(carpeta, ec)) {
      if (ec) break;
      if (!e.is_regular_file(ec)) continue;

      std::string ext = e.path().extension().string();
      std::transform(ext.begin(), ext.end(), ext.begin(),
                     [](unsigned char c) { return char(std::tolower(c)); });
      if (ext != ".iso") continue;

      std::string base = e.path().stem().string();
      std::transform(base.begin(), base.end(), base.begin(),
                     [](unsigned char c) { return char(std::tolower(c)); });

      if (!yo.empty() && base == yo) {
        preferida = e.path();
      } else {
        otras.push_back(e.path());
      }
    }

    if (!preferida.empty()) {
      paths.game_data_root = preferida;
    } else if (!otras.empty()) {
      std::sort(otras.begin(), otras.end());
      paths.game_data_root = otras.front();
    } else {
      // Sin ISO: una carpeta extraida al lado tambien vale. El parche de la
      // ISO dejo --game_data_root aceptando las dos cosas.
      const auto extraida = carpeta / "game_root";
      if (std::filesystem::is_directory(extraida, ec)) {
        paths.game_data_root = extraida;
      }
    }
    // Si no se encuentra nada, se deja vacio a proposito: el SDK dara su
    // propio mensaje, que es mas claro que cualquiera que pusieramos aqui.
  }

  // ==========================================================================
  //  2. AJUSTES OBLIGATORIOS
  //
  //  Para que "NFS_Most_Wanted.exe" a secas, sin un solo argumento, arranque
  //  igual de bien que con la linea de comandos larga de siempre.
  //
  //  Solo se tocan los que el usuario NO haya puesto: HasNonDefaultValue
  //  distingue "esto viene de fabrica" de "esto lo pidio alguien". Asi la
  //  linea de comandos y nfsmw.toml siguen mandando.
  //
  //  POR QUE EN DOS SITIOS DISTINTOS
  //  El cvar readback_resolve no existe todavia cuando arranca el logging: lo
  //  registra el plugin de GPU (rexgpu-xenos.dll), que se carga despues, en
  //  SetupPresentation. Ponerlo antes seria escribir sobre un flag que aun no
  //  existe. Por eso:
  //
  //    OnPostInitLogging  -> gpu_plugin y mnk_mode, que son del runtime y ya
  //                          estan registrados. Y tiene que ser AQUI, porque
  //                          SetupPresentation lee gpu_plugin justo despues.
  //    OnPostSetup        -> readback_resolve, cuando el plugin ya cargo y
  //                          todavia no se ha dibujado ni un fotograma.
  // ==========================================================================
  void OnPostInitLogging() override {
    // Sin plugin de GPU la pantalla se queda negra: el juego corre, pero el
    // runtime descarta sus llamadas graficas con "no GPU emulation loaded".
    PonerSiNadieLoPidio("gpu_plugin", "xenos");
    // Teclado y raton ademas del mando.
    PonerSiNadieLoPidio("mnk_mode", "true");
  }

  void OnPostSetup() override {
    // NO ES UNA PREFERENCIA, ES UN ARREGLO. El juego calcula su exposicion
    // midiendo el brillo medio de la escena y leyendo ese valor de vuelta en
    // la CPU. Esa lectura viene desactivada de fabrica ("none"), asi que el
    // juego recibe basura, deduce que la escena esta oscurisima y sube la
    // exposicion al maximo: imagen lavada y sol reventado.
    PonerSiNadieLoPidio("readback_resolve", "fast");

    // Contador de fps del overlay de F3, ver mas abajo. Devuelve lo ultimo
    // que midio el vigilante; no mide aqui, para que abrir el overlay no
    // cambie el numero que se esta leyendo.
    SetGuestFrameStats([this] { return stats_; });

    // Vigilante de cuelgues, ver mas abajo.
    ArrancarVigilante();
  }

  void OnShutdown() override { PararVigilante(); }

 private:
  static void PonerSiNadieLoPidio(const char* nombre, const char* valor) {
    if (rex::cvar::GetFlagInfo(nombre) == nullptr) {
      REXLOG_DEBUG("Ajuste '{}' no registrado todavia; no lo toco.", nombre);
      return;
    }
    if (rex::cvar::HasNonDefaultValue(nombre)) {
      return;  // lo puso el usuario: no se le lleva la contraria.
    }
    if (rex::cvar::SetFlagByName(nombre, valor)) {
      REXLOG_DEBUG("Ajuste por defecto de la build portable: {} = {}", nombre, valor);
    }
  }

  // ==========================================================================
  //  3. CONTADOR DE FPS PARA EL OVERLAY DE F3
  //
  //  En una build RELEASE, F3 abre una caja vacia que solo pone "Debug". Son
  //  dos cosas distintas y las dos estaban cerradas:
  //
  //    1. Casi todo el panel vive dentro de #ifdef REXGLUE_ENABLE_PERF_COUNTERS,
  //       y el CMakeLists del SDK dice
  //         add_compile_definitions($<$<NOT:$<CONFIG:Release>>:REXGLUE_ENABLE_PERF_COUNTERS>)
  //       o sea que en Release el define no se aplica. Es a proposito:
  //       "compiled out in Release", dice su comentario.
  //
  //    2. La linea "Guest: X FPS" NO esta dentro de ese #ifdef. Solo pide que
  //       alguien registre un proveedor con SetGuestFrameStats, y en el SDK no
  //       lo llama nadie: es una API que la app tiene que usar.
  //
  //  El (2) es la puerta que si se puede abrir sin tocar el SDK.
  //
  //  DE DONDE SALE EL NUMERO, Y POR QUE NO DE UN RELOJ DE AQUI.
  //  La primera version miraba el reloj cada vez que alguien preguntaba y daba
  //  el hueco entre dos preguntas por bueno como si fuera un fotograma. Con el
  //  overlay cerrado -toda corrida automatica- el unico que preguntaba era el
  //  vigilante, una vez por segundo: dt salia ~1000 ms, el filtro lo tiraba, y
  //  el log escribia 0.0 fps para siempre. No era lentitud, era el medidor.
  //
  //  El intento siguiente -un dialogo de ImGui contando en su OnDraw- si daba
  //  un numero, pero el EQUIVOCADO: contaba repintados de la INTERFAZ, que van
  //  por libre y llegan a 1770 por segundo mientras el juego da 17-30.
  //
  //  Un fotograma del juego solo existe en un sitio: cuando el presentador
  //  acepta una imagen nueva del guest. Eso es lo que cuenta el contador del
  //  SDK -PARCHE LOCAL en ui/presenter.h- y lo que se lee aqui. Se calcula por
  //  diferencia sobre el tic de un segundo del vigilante, asi que no hace
  //  falta ningun gancho por fotograma ni media movil: el intervalo es real.
  // ==========================================================================
  rex::ui::FrameStats MideFotogramas(double dt_s) {
    const auto* presentador =
        runtime() && runtime()->graphics_system() ? runtime()->graphics_system()->presenter() : nullptr;
    if (!presentador || dt_s <= 0.0) {
      return stats_;
    }
    const uint64_t ahora = presentador->guest_frames_refreshed();
    const uint64_t nuevos = ahora - fotogramas_previos_;
    fotogramas_previos_ = ahora;

    stats_.fps = double(nuevos) / dt_s;
    stats_.frame_time_ms = stats_.fps > 0.0 ? 1000.0 / stats_.fps : 0.0;
    stats_.frame_count = ahora;  // el overlay no dibuja si esto es 0
    return stats_;
  }

  // ==========================================================================
  //  4. VIGILANTE DE CUELGUES
  //
  //  EL PROBLEMA QUE RESUELVE
  //  Al volver al menu el juego se queda congelado, y en el log no aparece
  //  absolutamente nada: ni un error, ni una llamada al kernel, ni un comando
  //  grafico. Silencio total hasta que uno cierra la ventana. Eso descarta una
  //  excepcion o una funcion sin registrar -esas se ven- y deja una sola
  //  explicacion: TODOS los hilos del juego estan parados a la vez, esperando
  //  algo que no llega.
  //
  //  Y de un interbloqueo no se sale mirando el log, porque justamente lo que
  //  lo define es que ya no se escribe nada. Hay que ir a preguntarle a los
  //  hilos.
  //
  //  COMO FUNCIONA, Y POR QUE NO NECESITA QUE NADIE LE AVISE
  //  Un hilo aparte mira una vez por segundo TODOS los hilos del guest y anota
  //  dos registros de cada uno:
  //
  //    lr  a donde volveria la funcion en la que esta. Cambia constantemente
  //        en codigo que avanza.
  //    r1  el puntero de pila. Igual.
  //
  //  Si en varios segundos seguidos NINGUN hilo ha movido ninguno de los dos,
  //  el juego no esta lento: esta parado. Entonces se vuelca la tabla.
  //
  //  Lo bueno de medirlo asi es que no depende de nada: ni del contador de
  //  fotogramas -que solo corre con el overlay abierto-, ni de que el juego
  //  llame al kernel, ni de que el hilo grafico siga vivo. Si todo se para, se
  //  nota justo porque todo se para.
  //
  //  QUE SE SACA DEL VOLCADO
  //  Por cada hilo: su direccion de entrada -que dice QUE hilo es-, lr, r1 y
  //  r13. Con eso se distingue el que espera -lr clavado en una funcion de
  //  espera del kernel- del que da vueltas -lr saltando entre dos o tres
  //  direcciones-. Y como se vuelca cada 15 segundos mientras dure, se ve si
  //  algo se mueve muy despacio o no se mueve en absoluto.
  //
  //  COSTE CUANDO NO PASA NADA
  //  Una pasada por segundo leyendo dos enteros por hilo. Nada.
  //
  //  Vive en la app y no en el SDK a proposito: asi se toca sin recompilar el
  //  SDK entero, y no le impone a nadie mas un hilo de vigilancia.
  // ==========================================================================

  void ArrancarVigilante() {
    vigilante_activo_ = true;
    vigilante_ = std::thread([this] { VigilanteMain(); });
  }

  void PararVigilante() {
    vigilante_activo_ = false;
    if (vigilante_.joinable()) {
      vigilante_.join();
    }
  }

  // Volcado de la tabla de hilos. 'grave' decide si sale como error -cuando
  // es una alarma de verdad- o como debug -las instantaneas de rutina-.
  template <typename Lista>
  static void VolcarHilos(const Lista& hilos, bool grave) {
    for (auto& h : hilos) {
      const auto* cp = h->creation_params();
      auto* estado = h->thread_state();
      if (estado && estado->context()) {
        const auto& c = *estado->context();
        if (grave) {
          REXLOG_ERROR("[vigilante]   hilo id=0x{:X} entrada=0x{:08X} principal={} corriendo={} | "
                       "lr=0x{:08X} r1=0x{:08X} r13=0x{:08X} r3=0x{:08X} ctr=0x{:08X} "
                       "ultimo_indirecto=0x{:08X}",
                       h->thread_id(), cp->start_address, h->main_thread(), h->is_running(),
                       static_cast<uint32_t>(c.lr), c.r1.u32, c.r13.u32, c.r3.u32, c.ctr.u32,
                       c.last_indirect_target);
        } else {
          REXLOG_DEBUG("[vigilante]   hilo id=0x{:X} entrada=0x{:08X} principal={} corriendo={} | "
                       "lr=0x{:08X} r1=0x{:08X} r13=0x{:08X} r3=0x{:08X} ctr=0x{:08X} "
                       "ultimo_indirecto=0x{:08X}",
                       h->thread_id(), cp->start_address, h->main_thread(), h->is_running(),
                       static_cast<uint32_t>(c.lr), c.r1.u32, c.r13.u32, c.r3.u32, c.ctr.u32,
                       c.last_indirect_target);
        }
      } else {
        REXLOG_DEBUG("[vigilante]   hilo id=0x{:X} entrada=0x{:08X} sin contexto", h->thread_id(),
                     cp->start_address);
      }
    }
  }

  // ==========================================================================
  //  PERFILADOR DE CODIGO DEL JUEGO
  //
  //  EL PROBLEMA. El juego va a 15 fps -66 ms por fotograma- con el hilo
  //  principal al 90% de un nucleo y quince nucleos sin hacer nada. O sea que
  //  el limite es un solo hilo ejecutando codigo del juego. Falta saber QUE
  //  codigo, y ninguna herramienta de fuera lo dice: perf no esta instalado,
  //  ptrace_scope=1 impide que un perfilador hermano se enganche, y Tracy pide
  //  recompilar los 272 ficheros del recompilado y un visor aparte.
  //
  //  COMO SE MIDE SIN NADA DE ESO. El codigo generado escribe ctx.lr = <sitio
  //  al que se vuelve> justo antes de CADA llamada. Asi que lr, leido a menudo,
  //  es un contador de programa a escala de llamada: dice por que sitio del
  //  juego va el hilo. Y el contexto de cada hilo ya es accesible desde aqui;
  //  el vigilante de abajo lleva leyendolo desde el principio.
  //
  //  Mil muestras por segundo cuestan leer un entero mil veces: nada medible.
  //
  //  LO QUE NO ES. Las direcciones salen a resolucion de sitio-de-llamada, no
  //  de instruccion, y leer lr mientras el otro hilo corre es una carrera
  //  benigna -lectura alineada de 8 bytes en x86-64-. Para decidir DONDE mirar
  //  sobra; para microoptimizar una funcion concreta, no.
  //
  //  COMO SE LEE EL VOLCADO. Cada direccion se busca tal cual en
  //  generated/default/: aparece como "// bl 0x8...." en el sitio de llamada,
  //  dentro de la funcion sub_XXXXXXXX que se la esta comiendo.
  // ==========================================================================
  void MuestreaLr() {
    auto* kernel = rex::system::kernel_state();
    if (!kernel) return;
    if (!principal_) {
      for (auto& h : kernel->object_table()->GetObjectsByType<rex::system::XThread>()) {
        if (h->main_thread()) {
          principal_ = h;
          break;
        }
      }
      if (!principal_) return;
    }
    auto* estado = principal_->thread_state();
    if (!estado || !estado->context()) return;
    const auto& c = *estado->context();
    const uint32_t lr = static_cast<uint32_t>(c.lr);
    const uint32_t r1 = c.r1.u32;
    ++muestras_;
    ++perfil_[lr];

    // En el sitio caliente, con QUE se le esta llamando. r31 y r29 son copias
    // de los argumentos que hace sub_8258D9B0 nada mas entrar (mr r31,r3 y
    // mr r29,r5), y r3 es el primer argumento tal cual. Si r31 repite siempre
    // el mismo valor es un objeto unico -un dispositivo, un contexto-; si r29
    // cambia sin parar son recursos distintos pasando por el mismo sitio.
    if (lr == kSitioCaliente) {
      ++arg_r3_[c.r3.u32];
      ++arg_r29_[c.r29.u32];
      ++arg_r31_[c.r31.u32];
    }

    // ATASCADO O TRABAJANDO: la pregunta que decide todo. Una funcion de
    // cuarenta instrucciones sin bucles no puede comerse 45 ms por fotograma
    // ejecutando; o la llaman millones de veces, o el hilo esta PARADO ahi.
    // Si lr Y el puntero de pila repiten valor de una muestra a la siguiente,
    // es que no se ha movido: esta esperando, no calculando.
    if (lr == lr_anterior_ && r1 == r1_anterior_) {
      ++repetidas_;
    }
    lr_anterior_ = lr;
    r1_anterior_ = r1;
  }

  void VuelcaPerfil() {
    if (muestras_ < 100) return;
    std::vector<std::pair<uint32_t, uint64_t>> orden(perfil_.begin(), perfil_.end());
    std::partial_sort(orden.begin(), orden.begin() + std::min<size_t>(15, orden.size()),
                      orden.end(),
                      [](const auto& a, const auto& b) { return a.second > b.second; });
    REXLOG_INFO("[perfil] {} muestras del hilo principal, {} sitios distintos, "
                "{:.1f}% sin moverse respecto a la anterior (lr y r1 iguales). "
                "Los que mas salen:",
                muestras_, perfil_.size(), 100.0 * double(repetidas_) / double(muestras_));
    for (size_t i = 0; i < std::min<size_t>(15, orden.size()); ++i) {
      REXLOG_INFO("[perfil]   {:5.1f}%  lr=0x{:08X}  ({} muestras)",
                  100.0 * double(orden[i].second) / double(muestras_), orden[i].first,
                  orden[i].second);
    }
    VuelcaArgumentos("r3 ", arg_r3_);
    VuelcaArgumentos("r29", arg_r29_);
    VuelcaArgumentos("r31", arg_r31_);

    // Fallos de pagina de la memoria vigilada de la GPU. Es lo que queda por
    // bajar: ya no cuestan 26.000 ciclos cada uno -eso era el parseo de
    // /proc/self/maps- pero siguen costando ~1.100.
    const uint64_t cuadros = stats_.frame_count - fotogramas_perfil_;
    fotogramas_perfil_ = stats_.frame_count;
    const uint64_t vt = g_violaciones_totales.load(std::memory_order_relaxed);
    const uint64_t vf = g_violaciones_fisicas.load(std::memory_order_relaxed);
    const uint64_t dvt = vt - violaciones_totales_previas_;
    const uint64_t dvf = vf - violaciones_fisicas_previas_;
    violaciones_totales_previas_ = vt;
    violaciones_fisicas_previas_ = vf;
    REXLOG_INFO("[perfil] violaciones de acceso: {} en {} fotogramas = {} por fotograma "
                "({} de memoria fisica de la GPU, {} por fotograma)",
                dvt, cuadros, cuadros ? dvt / cuadros : 0, dvf, cuadros ? dvf / cuadros : 0);

    perfil_.clear();
    arg_r3_.clear();
    arg_r29_.clear();
    arg_r31_.clear();
    muestras_ = 0;
    repetidas_ = 0;
  }

  static void VuelcaArgumentos(const char* nombre, const std::map<uint32_t, uint64_t>& h) {
    if (h.empty()) return;
    std::vector<std::pair<uint32_t, uint64_t>> orden(h.begin(), h.end());
    const size_t cuantos = std::min<size_t>(4, orden.size());
    std::partial_sort(orden.begin(), orden.begin() + cuantos, orden.end(),
                      [](const auto& a, const auto& b) { return a.second > b.second; });
    uint64_t total = 0;
    for (const auto& [_, n] : h) total += n;
    std::string linea;
    for (size_t i = 0; i < cuantos; ++i) {
      linea += fmt::format("0x{:08X} ({:.0f}%)  ", orden[i].first,
                           100.0 * double(orden[i].second) / double(total));
    }
    REXLOG_INFO("[perfil]   {} = {} valores distintos. Top: {}", nombre, h.size(), linea);
  }

  void VigilanteMain() {
    using Reloj = std::chrono::steady_clock;

    // Cuantos segundos seguidos sin que se mueva NADA antes de dar la voz de
    // alarma. Cinco es holgado: este juego a 10 fps sigue moviendo registros
    // cien veces por segundo, asi que cinco segundos quietos no son lentitud.
    constexpr int kSegundosParaSospechar = 5;
    constexpr int kSegundosEntreVolcados = 15;

    uint64_t firma_anterior = 0;
    int quietos = 0;
    int desde_ultimo_volcado = 0;
    int desde_instantanea = 0;
    bool avisado = false;

    while (vigilante_activo_) {
      // El segundo de espera se gasta muestreando, no durmiendo de una vez.
      // Ver MuestreaLr: mil muestras por segundo del hilo principal.
      for (int ms = 0; ms < 1000 && vigilante_activo_; ++ms) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        MuestreaLr();
      }
      if (!vigilante_activo_) break;

      if (++desde_perfil_ >= kSegundosEntrePerfiles) {
        desde_perfil_ = 0;
        VuelcaPerfil();
      }

      // PARCHE LOCAL - contador de fps en el log, sin abrir el F3.
      //
      // El tic de este bucle es de un segundo y es el propio intervalo de
      // medida: fotogramas nuevos del juego partido por el tiempo que ha
      // pasado de verdad. Se imprime cada cinco.
      const auto s = MideFotogramas(1.0);
      if (++desde_log_fps_ >= 5) {
        desde_log_fps_ = 0;
        REXLOG_INFO("[fps] {:5.1f} ({:5.1f} ms, {} fotogramas)", s.fps, s.frame_time_ms,
                    s.frame_count);
      }

      auto* kernel = rex::system::kernel_state();
      if (!kernel) continue;

      auto hilos = kernel->object_table()->GetObjectsByType<rex::system::XThread>();
      if (hilos.empty()) continue;

      // Una firma de "por donde va todo el mundo". No hace falta que sea
      // buena como hash: solo tiene que cambiar si cambia algun registro.
      //
      // OJO CON EL ORDEN. La primera version de esto multiplicaba y mezclaba
      // sobre la marcha, recorriendo la lista tal cual venia. Y GetObjectsByType
      // NO garantiza el orden: en los volcados reales los hilos salian barajados
      // de una vuelta a otra, y hasta repetidos -el 0x6 aparecia dos veces-. O
      // sea que la firma cambiaba sola aunque no se moviera nada, y la alarma
      // no salto NUNCA en el cuelgue de verdad. Lo unico que sirvio de algo
      // fueron las instantaneas periodicas de mas abajo.
      //
      // Se arregla metiendo cada hilo en un mapa por su id: el mapa ordena
      // solo, asi que el barajado deja de importar, y un id repetido se
      // machaca en vez de contarse dos veces. Recien entonces se mezcla.
      std::map<uint32_t, uint64_t> por_hilo;
      for (auto& h : hilos) {
        auto* estado = h->thread_state();
        if (!estado || !estado->context()) continue;
        const auto& c = *estado->context();
        por_hilo[h->thread_id()] =
            static_cast<uint64_t>(c.lr) ^ (static_cast<uint64_t>(c.r1.u32) << 20) ^
            (static_cast<uint64_t>(c.r3.u32) << 40);
      }

      uint64_t firma = 1469598103934665603ull;
      for (const auto& [id_hilo, huella] : por_hilo) {
        firma = (firma ^ id_hilo) * 1099511628211ull;
        firma = (firma ^ huella) * 1099511628211ull;
      }

      // INSTANTANEA PERIODICA, PASE LO QUE PASE.
      //
      // La alarma de arriba solo salta si NADA se mueve, y resulto que el
      // cuelgue que perseguimos no es de ese tipo: los registros seguian
      // cambiando, o sea que el juego ejecuta codigo pero no avanza. Un bucle
      // cerrado esperando algo que no llega se ve igual de parado por fuera y
      // sin embargo la alarma no lo pilla.
      //
      // Para eso esta esto: cada diez segundos se apunta por donde va cada
      // hilo, haya o no problema. Cuando el juego se congela, quedan dos o
      // tres instantaneas del rato malo, y si lr da vueltas entre las mismas
      // dos o tres direcciones, ahi esta el bucle.
      //
      // Va a nivel debug -no molesta en uso normal- y son unas pocas lineas
      // cada diez segundos.
      if (++desde_instantanea >= 10) {
        desde_instantanea = 0;
        REXLOG_DEBUG("[vigilante] instantanea: {} hilos del juego", hilos.size());
        VolcarHilos(hilos, false);
      }

      if (firma != firma_anterior) {
        if (avisado) {
          REXLOG_WARN("[vigilante] el juego ha vuelto a moverse despues de {} s parado.", quietos);
          avisado = false;
        }
        firma_anterior = firma;
        quietos = 0;
        desde_ultimo_volcado = 0;
        continue;
      }

      ++quietos;
      ++desde_ultimo_volcado;
      if (quietos < kSegundosParaSospechar) continue;
      if (avisado && desde_ultimo_volcado < kSegundosEntreVolcados) continue;
      desde_ultimo_volcado = 0;

      REXLOG_ERROR("[vigilante] {} s sin que se mueva ni un registro en ninguno de los {} hilos "
                   "del juego. Esto no es lentitud: esta parado.",
                   quietos, hilos.size());
      VolcarHilos(hilos, true);
      avisado = true;
    }
  }

  // Solo los toca el hilo del vigilante, que es el unico que mide.
  rex::ui::FrameStats stats_{};
  uint64_t fotogramas_previos_ = 0;
  int desde_log_fps_ = 0;

  // Perfilador, tambien solo del hilo del vigilante.
  static constexpr int kSegundosEntrePerfiles = 20;
  rex::system::object_ref<rex::system::XThread> principal_;
  static constexpr uint32_t kSitioCaliente = 0x8258D9B8;  // dentro de sub_8258D9B0
  std::map<uint32_t, uint64_t> perfil_;
  std::map<uint32_t, uint64_t> arg_r3_, arg_r29_, arg_r31_;
  uint64_t muestras_ = 0;
  uint64_t repetidas_ = 0;
  uint32_t lr_anterior_ = 0;
  uint32_t r1_anterior_ = 0;
  uint64_t violaciones_totales_previas_ = 0;
  uint64_t violaciones_fisicas_previas_ = 0;
  uint64_t fotogramas_perfil_ = 0;
  int desde_perfil_ = 0;

  std::thread vigilante_;
  std::atomic<bool> vigilante_activo_{false};
};
