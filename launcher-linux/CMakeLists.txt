set(CMAKE_AUTOMOC ON)

add_executable(nfsmw_launcher
    main.cpp
    main_window.cpp
    main_window.h
    game_config.cpp
    game_config.h
    import_service.cpp
    import_service.h
)

target_link_libraries(nfsmw_launcher PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
)

target_compile_features(nfsmw_launcher PRIVATE cxx_std_23)
target_compile_definitions(nfsmw_launcher PRIVATE
    NFSMW_LAUNCHER_VERSION="0.1.0"
)

if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
    target_compile_options(nfsmw_launcher PRIVATE -march=armv8.4-a)
endif()

include(GNUInstallDirs)
install(TARGETS nfsmw_launcher
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

if(NFSMW_LAUNCHER_BUILD_TESTS)
    find_package(Qt6 6.4 COMPONENTS Test QUIET)
    if(TARGET Qt6::Test)
        add_executable(nfsmw_launcher_config_test
            tests/config_test.cpp
            game_config.cpp
            game_config.h
            import_service.cpp
            import_service.h
        )
        target_include_directories(nfsmw_launcher_config_test PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR})
        target_link_libraries(nfsmw_launcher_config_test PRIVATE
            Qt6::Core Qt6::Test)
        add_test(NAME nfsmw_launcher_config_test
                 COMMAND nfsmw_launcher_config_test)
    endif()
endif()
