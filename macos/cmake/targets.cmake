# The three applications. Included at the end of PuTTY's top-level
# CMakeLists.txt by inject.cmake, so all of PuTTY's libraries and helper
# functions (be_list etc.) are available here.
#
# Source layout (see docs/ARCHITECTURE.md):
#   macos/shared/     code more than one application uses
#   macos/MacTTY/     the terminal application
#   macos/MacTTYgen/  the key generator (PuTTYgen)
#   macos/Pageant/    the SSH agent
# Includes are written from those roots, e.g. "Session/Session.h" inside
# MacTTY and "shared/eventloop.h" anywhere, so that a file's first lines
# say which parts of the program it depends on.

include(${MACTTY_DIR}/cmake/app-icon.cmake)

# MacTTY's own version (VERSION at the top of the repository) goes into
# the Info.plist of all three applications; PuTTY's stays in ver[].
file(STRINGS ${MACTTY_DIR}/../VERSION MACTTY_VERSION LIMIT_COUNT 1)
set_property(DIRECTORY APPEND PROPERTY
  CMAKE_CONFIGURE_DEPENDS ${MACTTY_DIR}/../VERSION)

set(SHARED ${MACTTY_DIR}/shared)

# ----------------------------------------------------------------------
# MacTTY: the terminal application.

set(APP ${MACTTY_DIR}/MacTTY)
set(MACTTY_OBJC_SOURCES
  ${APP}/App/main.m
  ${APP}/App/AppDelegate.m
  ${APP}/App/alerts.m
  ${APP}/Session/Session.m
  ${APP}/Session/SessionFrontend.m
  ${APP}/Session/SecurityPrompt.m
  ${APP}/Session/EventLog.m
  ${APP}/Session/recent-sessions.m
  ${APP}/Terminal/TerminalView.m
  ${APP}/Config/ConfigDialog.m
  ${APP}/Platform/platform-mac.m
  ${SHARED}/eventloop.m)

add_executable(MacTTY MACOSX_BUNDLE
  ${MACTTY_OBJC_SOURCES}
  ${APP}/Config/config-mac.c
  ${SHARED}/agent-socket.c
  ${CMAKE_SOURCE_DIR}/unix/unicode.c
  ${CMAKE_SOURCE_DIR}/unix/printing.c
  ${CMAKE_SOURCE_DIR}/unix/config-unix.c
  ${CMAKE_SOURCE_DIR}/stubs/no-console.c)
be_list(MacTTY MacTTY SSH SERIAL OTHERBACKENDS)
mactty_app_icon(MacTTY)
add_dependencies(MacTTY generated_licence_h)
target_include_directories(MacTTY PRIVATE ${APP} ${MACTTY_DIR})
set_source_files_properties(${MACTTY_OBJC_SOURCES}
  PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(MacTTY
  guiterminal eventloop sshclient otherbackends settings
  network crypto utils ${platform_libraries}
  "-framework Cocoa" "-framework Carbon" "-framework CoreText"
  "-framework UniformTypeIdentifiers" "-framework IOKit")
set_target_properties(MacTTY PROPERTIES
  LINK_INTERFACE_MULTIPLICITY 2
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
  MACOSX_BUNDLE_INFO_PLIST ${APP}/Info.plist.in)

# PuTTY's command-line tools travel inside the application bundle, as
# they come with PuTTY on Windows.
set(MACTTY_TOOLS plink pscp psftp puttygen pageant)
add_dependencies(MacTTY ${MACTTY_TOOLS})
foreach(tool ${MACTTY_TOOLS})
  add_custom_command(TARGET MacTTY POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
      $<TARGET_BUNDLE_CONTENT_DIR:MacTTY>/Resources/bin
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      $<TARGET_FILE:${tool}> $<TARGET_BUNDLE_CONTENT_DIR:MacTTY>/Resources/bin/)
endforeach()

# ----------------------------------------------------------------------
# The companion applications, PuTTYgen and Pageant, are separate
# programs as they are on Windows (one process per tool keeps the key
# generator's worker thread away from live sessions' random pool, and
# lets the agent outlive the terminal windows). They are built straight
# into MacTTY.app/Contents/Applications, so that MacTTY can start them
# from its menu and they travel with it.

set(MACTTY_TOOLS_DIR ${CMAKE_BINARY_DIR}/MacTTY.app/Contents/Applications)

# MacTTYgen: the key generator.
set(MACTTYGEN_OBJC_SOURCES
  ${MACTTY_DIR}/MacTTYgen/Keygen.m
  ${SHARED}/companion.m)
add_executable(MacTTYgen MACOSX_BUNDLE
  ${MACTTYGEN_OBJC_SOURCES}
  ${CMAKE_SOURCE_DIR}/stubs/no-timing.c
  ${CMAKE_SOURCE_DIR}/unix/keygen-noise.c
  ${CMAKE_SOURCE_DIR}/unix/no-gtk.c
  ${CMAKE_SOURCE_DIR}/unix/noise.c
  ${CMAKE_SOURCE_DIR}/unix/storage.c
  ${CMAKE_SOURCE_DIR}/sshpubk.c
  ${CMAKE_SOURCE_DIR}/sshrand.c)
mactty_app_icon(MacTTYgen)
add_dependencies(MacTTYgen generated_licence_h)
target_include_directories(MacTTYgen PRIVATE ${MACTTY_DIR})
set_source_files_properties(${MACTTYGEN_OBJC_SOURCES}
  PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(MacTTYgen keygen crypto utils
  "-framework Cocoa" "-framework UniformTypeIdentifiers")
set_target_properties(MacTTYgen PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY ${MACTTY_TOOLS_DIR}
  MACOSX_BUNDLE_INFO_PLIST ${MACTTY_DIR}/MacTTYgen/Info.plist.in)
add_dependencies(MacTTY MacTTYgen)

# Pageant: the SSH agent.
set(PAGEANT_OBJC_SOURCES
  ${MACTTY_DIR}/Pageant/Pageant.m
  ${SHARED}/companion.m
  ${SHARED}/eventloop.m)
add_executable(Pageant MACOSX_BUNDLE
  ${PAGEANT_OBJC_SOURCES}
  ${SHARED}/agent-socket.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/unix/noise.c
  ${CMAKE_SOURCE_DIR}/unix/unicode.c
  ${CMAKE_SOURCE_DIR}/unix/no-gtk.c
  ${CMAKE_SOURCE_DIR}/ssh/x11fwd.c
  ${CMAKE_SOURCE_DIR}/proxy/nosshproxy.c)
mactty_app_icon(Pageant)
be_list(Pageant Pageant)
add_dependencies(Pageant generated_licence_h)
target_include_directories(Pageant PRIVATE ${MACTTY_DIR})
set_source_files_properties(${PAGEANT_OBJC_SOURCES}
  PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(Pageant
  eventloop agent settings network crypto utils
  "-framework Cocoa")
set_target_properties(Pageant PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY ${MACTTY_TOOLS_DIR}
  MACOSX_BUNDLE_INFO_PLIST ${MACTTY_DIR}/Pageant/Info.plist.in)
add_dependencies(MacTTY Pageant)

# ----------------------------------------------------------------------
# All three.

set_target_properties(MacTTY MacTTYgen Pageant PROPERTIES
  MACOSX_BUNDLE_SHORT_VERSION_STRING ${MACTTY_VERSION}
  MACOSX_BUNDLE_BUNDLE_VERSION ${MACTTY_VERSION})

# PuTTY must never be built with NDEBUG; setup.cmake strips it from the C
# flags, so strip it from the Objective-C ones too.
foreach(cfg RELEASE RELWITHDEBINFO MINSIZEREL)
  string(REPLACE "-DNDEBUG" "" CMAKE_OBJC_FLAGS_${cfg}
    "${CMAKE_OBJC_FLAGS_${cfg}}")
endforeach()
