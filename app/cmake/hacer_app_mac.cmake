# =============================================================================
#  hacer_app_mac.cmake - arma NFSMW.app sobre la carpeta build/mac/
#
#  Lo lanza el target "mac_app" de app/CMakeLists.txt en modo script (-P).
#
#      build/mac/NFSMW.app/
#        Contents/MacOS/nfsmw                 el juego (el mismo de la dist)
#        Contents/MacOS/librexgpu-xenos.dylib el plugin de GPU, junto al exe:
#                                             el loader del SDK lo dlopen'a con
#                                             nombre fijo exe_dir/<nombre>
#        Contents/MacOS/lib                   atajo a ../Frameworks: hace que
#                                             el runtime vea el layout que
#                                             reconoce (ver NOTAS)
#        Contents/Frameworks/                 las mismas dylibs de la dist/lib
#        Contents/Resources/vulkan/icd.d/     el ICD re-targetado
#        Contents/Resources/                  nfsmw.toml y README.txt
#
#  FIRMA AD HOC: sin firmar no arranca en Apple Silicon.
#
#  NOTAS DE IMPLEMENTACION (adaptaciones sobre el borrador del plan):
#    - El material sale de la DIST relinkada (D_DIST), no del build dir: el
#      nfsmw del build lleva rpaths absolutos al install del SDK y no es
#      reubicable. mac_dist ya lo paso por relink.sh (IDs y deps a @rpath) y
#      comprobar_dist.sh; el target mac_app depende de mac_dist, asi que el
#      material es siempre fresco. Solo hay que re-firmar lo que se toque
#      aqui: el binario y el plugin (nuevos rpaths). Las dylibs de Frameworks
#      se copian intactas; se refirman igualmente para uniformidad.
#    - El plugin de GPU viaja plano junto al ejecutable (dlopen de ruta fija)
#      y con rpath propio @loader_path/../Frameworks: en el bundle las dylibs
#      viven en Contents/Frameworks, no en lib/.
#    - Contents/MacOS/lib -> ../Frameworks (atajo relativo): la deteccion
#      propia del runtime (vulkan_moltenvk.cpp) busca un "raiz" que lleve
#      lib/libvulkan.1.dylib al lado del ejecutable; sin ese enlace el bundle
#      no es un raiz reconocido, y el runtime se va a los fallbacks
#      (/usr/local, /opt/homebrew): en una maquina con homebrew Vulkan carga
#      el loader ajeno y en una maquina limpia no encuentra loader ninguno.
#      El enlace reparte el layout de la dist dentro de Contents/MacOS sin
#      duplicar dylibs, y codesign lo acepta (los destinos relativos son
#      validos; uno absoluto NO: comprobado).
#    - El ICD se re-targeta a un path RELATIVO al propio json, no a
#      @executable_path: el loader Vulkan NO expande @executable_path en
#      library_path (loader.c: combine_manifest_directory_and_library_path
#      solo trata absolute, nombre desnudo o relativo; el error real fue
#      "Failed loading library associated with ICD JSON
#      <dir del json>/@executable_path/../..."). Desde Contents/Resources/
#      vulkan/icd.d/, ../../../Frameworks/ cae en Contents/Frameworks: mismo
#      mecanismo relativo que ya usa la dist con exito. Con el layout de
#      MacOS/lib reconocido, ademas el propio runtime fija VK_DRIVER_FILES
#      al ICD del bundle.
#    - nfsmw.toml SOLO en Contents/Resources: el SDK lo lee y lo guarda de
#      exe_dir (rex_app.cpp: config_path = exe_dir/<name>.toml), pero codesign
#      trata TODO lo que hay bajo Contents/MacOS como codigo anidado y se
#      niega a firmar el bundle si viaja ahi un archivo suelto sin firmar
#      ("code object is not signed at all / In subcomponent: nfsmw.toml").
#      El juego crea su copia de trabajo en Contents/MacOS a demanda; la de
#      Resources queda como plantilla visible para el usuario.
#    - La comprobacion es una pasada otool propia en vez de comprobar_dist.sh:
#      el layout del bundle (Frameworks/, plugin plano en MacOS/) no encaja en
#      el de la dist (lib/). Mismo criterio: todo @rpath resuelto contra
#      Frameworks, o dylib del sistema (/usr/lib, /System/Library). Cualquier
#      otra ruta absoluta es fatal.
# =============================================================================
cmake_minimum_required(VERSION 3.25)

foreach(v D_DIST D_BUNDLE D_PLIST D_VERSION D_ICD D_CONFIG D_README)
    if(NOT DEFINED ${v})
        message(FATAL_ERROR "hacer_app_mac.cmake: falta ${v}")
    endif()
endforeach()

file(REMOVE_RECURSE "${D_BUNDLE}")
file(MAKE_DIRECTORY "${D_BUNDLE}/Contents/MacOS" "${D_BUNDLE}/Contents/Frameworks"
                    "${D_BUNDLE}/Contents/Resources/vulkan/icd.d")

set(NFSMW_VERSION "${D_VERSION}")
configure_file("${D_PLIST}" "${D_BUNDLE}/Contents/Info.plist" @ONLY)

# ---- El material sale de la dist relinkada -----------------------------------
foreach(f nfsmw librexgpu-xenos.dylib)
    if(NOT EXISTS "${D_DIST}/${f}")
        message(FATAL_ERROR "hacer_app_mac.cmake: no esta ${D_DIST}/${f} "
                            "(¿corrio mac_dist antes?)")
    endif()
endforeach()
file(GLOB DIST_LIBS "${D_DIST}/lib/*.dylib")
if(NOT DIST_LIBS)
    message(FATAL_ERROR "hacer_app_mac.cmake: no hay dylibs en ${D_DIST}/lib")
endif()
if(NOT EXISTS "${D_DIST}/share/vulkan/icd.d/MoltenVK_icd.json")
    message(FATAL_ERROR "hacer_app_mac.cmake: no hay ICD en ${D_DIST}/share/vulkan/icd.d")
endif()

# ---- El binario y el plugin de GPU, en Contents/MacOS ------------------------
file(COPY "${D_DIST}/nfsmw" "${D_DIST}/librexgpu-xenos.dylib"
     DESTINATION "${D_BUNDLE}/Contents/MacOS")

# ---- Las dylibs del proyecto y del stack Vulkan, en Contents/Frameworks ------
file(COPY ${DIST_LIBS} DESTINATION "${D_BUNDLE}/Contents/Frameworks")

# ---- El ICD, re-targetado al layout del bundle -------------------------------
#  El json del SDK apunta a ../../../lib/libMoltenVK.dylib (layout del
#  install); desde Contents/Resources/vulkan/icd.d/ eso caeria fuera. El
#  loader del bundle lo busca en Contents/Resources/vulkan/icd.d (CFBundle
#  resource dir) y resuelve library_path relativo AL PROPIO json: mismo
#  mecanismo que la dist, distinto destino (ver las NOTAS de cabecera).
file(READ "${D_ICD}" icd_content)
string(REPLACE "../../../lib/libMoltenVK.dylib"
               "../../../Frameworks/libMoltenVK.dylib"
               icd_content "${icd_content}")
string(FIND "${icd_content}" "../../../Frameworks/libMoltenVK.dylib" icd_pos)
if(icd_content STREQUAL "" OR icd_pos EQUAL -1)
    message(FATAL_ERROR "hacer_app_mac.cmake: el ICD no trae "
                        "../../../lib/libMoltenVK.dylib, revisar el retarget")
endif()
file(WRITE "${D_BUNDLE}/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json"
           "${icd_content}")

# ---- El atajo Contents/MacOS/lib -> ../Frameworks ----------------------------
#  Hace que la deteccion del runtime vea lib/libvulkan.1.dylib junto al
#  ejecutable (kRootMarkers de vulkan_moltenvk.cpp) y cargue el loader del
#  bundle en vez de irse a /opt/homebrew o fallar en una maquina limpia.
#  El destino ha de ser RELATIVO: codesign rechaza un enlace absoluto dentro
#  del bundle ("invalid destination for symbolic link in bundle").
file(CREATE_LINK "../Frameworks" "${D_BUNDLE}/Contents/MacOS/lib" SYMBOLIC)

# ---- Config y README ----------------------------------------------------------
#  El toml en Resources (codesign no deja nada sin firmar en Contents/MacOS;
#  el juego crea el suyo alli a demanda); el README describe la carpeta dist,
#  sirve igual.
file(COPY "${D_CONFIG}" "${D_README}" DESTINATION "${D_BUNDLE}/Contents/Resources")

# ---- RPATH del bundle y firma ad hoc -----------------------------------------
#  Las dylibs de la dist ya responden a @rpath/<name> (IDs y deps puestos por
#  relink.sh) y traen rpath @loader_path: en Frameworks son hermanas y les
#  basta. El binario, en cambio, apuntaba a @executable_path/lib (layout de la
#  dist): aqui hace falta @executable_path/../Frameworks. El plugin plano
#  lleva los rpaths del build (@loader_path, @loader_path/../lib), ninguno
#  alcanza Frameworks: se le anade el suyo (endurecimiento del fallo menor de
#  la tarea 4: que el plugin sea autosuficiente y no dependa del fallback del
#  ejecutable principal). Modificarlos invalida la firma y Apple Silicon mata
#  el proceso al arrancar: re-firmar binario, plugin y dylibs, y despues el
#  bundle entero.
find_program(CS codesign REQUIRED)
find_program(INT install_name_tool REQUIRED)
find_program(OT otool REQUIRED)
file(GLOB FW_DYLIBS "${D_BUNDLE}/Contents/Frameworks/*.dylib")

foreach(par "nfsmw;@executable_path/../Frameworks"
            "librexgpu-xenos.dylib;@loader_path/../Frameworks")
    list(GET par 0 nombre)
    list(GET par 1 rpath)
    execute_process(COMMAND ${INT} -add_rpath "${rpath}"
                    "${D_BUNDLE}/Contents/MacOS/${nombre}"
                    RESULT_VARIABLE rc ERROR_QUIET)
    if(NOT rc EQUAL 0)
        message(FATAL_ERROR "hacer_app_mac.cmake: no pude anadir el rpath "
                            "${rpath} a ${nombre} (${rc})")
    endif()
    execute_process(COMMAND ${OT} -l "${D_BUNDLE}/Contents/MacOS/${nombre}"
                    OUTPUT_VARIABLE rpaths ERROR_QUIET)
    string(FIND "${rpaths}" "path ${rpath}" rpath_pos)
    if(rpath_pos EQUAL -1)
        message(FATAL_ERROR "hacer_app_mac.cmake: el rpath ${rpath} no quedo "
                            "en ${nombre}")
    endif()
endforeach()

foreach(f "${D_BUNDLE}/Contents/MacOS/nfsmw"
          "${D_BUNDLE}/Contents/MacOS/librexgpu-xenos.dylib")
    execute_process(COMMAND ${CS} -f -s - "${f}" RESULT_VARIABLE rc)
    if(NOT rc EQUAL 0)
        message(FATAL_ERROR "hacer_app_mac.cmake: codesign fallo en ${f} (${rc})")
    endif()
endforeach()
foreach(dylib IN LISTS FW_DYLIBS)
    execute_process(COMMAND ${CS} -f -s - "${dylib}" RESULT_VARIABLE rc)
    if(NOT rc EQUAL 0)
        message(FATAL_ERROR "hacer_app_mac.cmake: codesign fallo en ${dylib} (${rc})")
    endif()
endforeach()
execute_process(COMMAND ${CS} -f -s - "${D_BUNDLE}" RESULT_VARIABLE rc)
if(NOT rc EQUAL 0)
    message(FATAL_ERROR "hacer_app_mac.cmake: codesign del bundle fallo (${rc})")
endif()
execute_process(COMMAND ${CS} --verify --deep --strict "${D_BUNDLE}"
                RESULT_VARIABLE rc OUTPUT_QUIET ERROR_QUIET)
if(NOT rc EQUAL 0)
    message(FATAL_ERROR "hacer_app_mac.cmake: codesign --verify fallo (${rc})")
endif()

# ---- Comprobacion: el bundle es autocontenido ---------------------------------
#  Misma regla que comprobar_dist.sh, adaptada al layout: cada dependencia de
#  nfsmw, del plugin plano y de las dylibs de Frameworks se resuelve contra
#  Contents/Frameworks si es @rpath, o es del sistema (/usr/lib,
#  /System/Library). Otra ruta absoluta es fatal: rompe al mover el bundle.
function(comprobar_binario f fw)
    execute_process(COMMAND ${OT} -L "${f}"
                    OUTPUT_VARIABLE deps ERROR_QUIET)
    string(REGEX MATCHALL "\t[^ \t\n]+" crudas "${deps}")
    set(rc 0)
    foreach(cruda IN LISTS crudas)
        string(STRIP "${cruda}" dep)
        string(FIND "${dep}" "@rpath/" en_rpath)
        if(en_rpath EQUAL 0)
            get_filename_component(nombre "${dep}" NAME)
            if(NOT EXISTS "${fw}/${nombre}")
                message("[ERROR] ${f}: @rpath sin destino: ${dep}")
                set(rc 1)
            endif()
        elseif(dep MATCHES "^/usr/lib/|^/System/Library/") # dylib del sistema
        else()
            message("[ERROR] ${f}: dependencia ni @rpath ni del sistema: ${dep}")
            set(rc 1)
        endif()
    endforeach()
    if(NOT rc EQUAL 0)
        message(FATAL_ERROR "hacer_app_mac.cmake: ${f} no es autocontenido")
    endif()
endfunction()
comprobar_binario("${D_BUNDLE}/Contents/MacOS/nfsmw" "${D_BUNDLE}/Contents/Frameworks")
comprobar_binario("${D_BUNDLE}/Contents/MacOS/librexgpu-xenos.dylib"
                  "${D_BUNDLE}/Contents/Frameworks")
foreach(dylib IN LISTS FW_DYLIBS)
    comprobar_binario("${dylib}" "${D_BUNDLE}/Contents/Frameworks")
endforeach()

message(STATUS "hacer_app_mac.cmake: NFSMW.app listo y firmado en ${D_BUNDLE}")
