# =============================================================================
#  hacer_dist_mac.cmake - arma la carpeta autocontenida  build/mac/
#
#  Lo lanza el target "mac_dist" de app/CMakeLists.txt en modo script (-P).
#  El layout replica el del install del SDK (lib/, share/vulkan/icd.d/) para
#  que el ICD que viaja dentro y la deteccion propia del runtime (vulkan_
#  moltenvk.cpp) funcionen tal cual. El ejecutable conserva el nombre
#  nfsmw, que es como lo llama tools/run.sh en Linux.
#
#  LA ISO NO SE COPIA: igual que en Windows, el usuario pone su juego (un
#  .iso o la carpeta game_root/) junto al binario. comprobar_dist.sh se
#  niega a dar la carpeta por buena si viaja cualquier cosa que parezca
#  juego.
# =============================================================================
cmake_minimum_required(VERSION 3.25)

foreach(v D_DIST D_EXE D_BUILD D_SDK_INSTALL D_VULKAN_LOADER D_MOLTENVK
           D_SDL3 D_ICD D_CONFIG D_README D_PACKAGING)
    if(NOT DEFINED ${v})
        message(FATAL_ERROR "hacer_dist_mac.cmake: falta ${v}")
    endif()
endforeach()

file(REMOVE_RECURSE "${D_DIST}")
file(MAKE_DIRECTORY "${D_DIST}" "${D_DIST}/lib" "${D_DIST}/share/vulkan/icd.d")

# ---- El juego ---------------------------------------------------------------
execute_process(COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${D_EXE}" "${D_DIST}/nfsmw")

# ---- Dylibs del proyecto: del build dir, o del install del SDK ---------------
#  Igual que en Windows (hacer_dist.cmake), rexruntime y el plugin de GPU se
#  cargan en runtime (dlopen) y no figuran en las dependencias del enlazador:
#  hay que copiarlos a mano. Salen del directorio de compilacion si el helper
#  del SDK los copia junto al exe; si no, del install del SDK. Si el runtime
#  solo existe como estatica (.a) van dentro del binario y no hay nada que
#  llevar: no es error.
set(DYLIBS)
file(GLOB DYLIBS "${D_BUILD}/*.dylib")
foreach(n librexruntime librexgpu-xenos)
    file(GLOB hit "${D_BUILD}/${n}*.dylib")
    if(NOT hit)
        file(GLOB hit "${D_SDK_INSTALL}/lib/${n}*.dylib")
    endif()
    if(hit)
        list(APPEND DYLIBS ${hit})
    elseif(NOT EXISTS "${D_SDK_INSTALL}/lib/${n}.a")
        message(FATAL_ERROR "hacer_dist_mac.cmake: no encuentro ${n} ni dylib ni "
                            "estatica (busque en ${D_BUILD} y ${D_SDK_INSTALL}/lib)")
    endif()
endforeach()
foreach(dylib IN LISTS DYLIBS)
    file(COPY "${dylib}" DESTINATION "${D_DIST}/lib")
endforeach()

# ---- El plugin de GPU, junto al ejecutable -----------------------------------
#  El loader del SDK (gpu_plugin_loader.cpp) lo dlopen'a desde la carpeta del
#  ejecutivo con nombre fijo: exe_dir/librexgpu-xenos.dylib. No es negociable.
file(GLOB hit "${D_BUILD}/librexgpu-xenos*.dylib")
if(NOT hit)
    file(GLOB hit "${D_SDK_INSTALL}/lib/librexgpu-xenos*.dylib")
endif()
list(LENGTH hit hit_n)
if(hit_n EQUAL 1)
    list(GET hit 0 hit)
    file(COPY "${hit}" DESTINATION "${D_DIST}")
elseif(hit_n GREATER 1)
    message(FATAL_ERROR "hacer_dist_mac.cmake: varios librexgpu-xenos* "
                        "(postfix por config) en el build dir: desambigua")
else()
    message(FATAL_ERROR "hacer_dist_mac.cmake: no encuentro librexgpu-xenos*.dylib "
                        "(busque en ${D_BUILD} y ${D_SDK_INSTALL}/lib)")
endif()

# ---- Stack Vulkan->MoltenVK y SDL3, del install del SDK ----------------------
#  El ICD viaja intacto: su library_path es ../../../lib/libMoltenVK.dylib,
#  que resuelve dentro de la carpeta. SDL3 solo si es dylib (si salio
#  estatica no hay nada que llevar).
if(NOT "${D_VULKAN_LOADER}" STREQUAL "")
    file(COPY "${D_VULKAN_LOADER}" DESTINATION "${D_DIST}/lib")
endif()
if(NOT "${D_MOLTENVK}" STREQUAL "")
    file(COPY "${D_MOLTENVK}" DESTINATION "${D_DIST}/lib")
endif()
if("${D_SDL3}" MATCHES "\\.dylib$")
    file(COPY "${D_SDL3}" DESTINATION "${D_DIST}/lib")
endif()
if(NOT "${D_ICD}" STREQUAL "")
    file(COPY "${D_ICD}" DESTINATION "${D_DIST}/share/vulkan/icd.d/")
endif()

# ---- Config y README ---------------------------------------------------------
file(COPY "${D_CONFIG}" DESTINATION "${D_DIST}")
file(COPY "${D_README}" DESTINATION "${D_DIST}")

# ---- Relink y comprobacion ---------------------------------------------------
execute_process(COMMAND "${D_PACKAGING}/relink.sh" "${D_DIST}"
    RESULT_VARIABLE rc COMMAND_ECHO STDOUT)
if(NOT rc EQUAL 0)
    message(FATAL_ERROR "hacer_dist_mac.cmake: relink.sh fallo (${rc})")
endif()
execute_process(COMMAND "${D_PACKAGING}/comprobar_dist.sh" "${D_DIST}"
    RESULT_VARIABLE rc COMMAND_ECHO STDOUT)
if(NOT rc EQUAL 0)
    message(FATAL_ERROR "hacer_dist_mac.cmake: comprobar_dist.sh fallo (${rc})")
endif()
