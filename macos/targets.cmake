# The MacTTY application. Included at the end of PuTTY's top-level
# CMakeLists.txt by inject.cmake, so all of PuTTY's libraries and helper
# functions (be_list etc.) are available here.

# MacTTY's own version (VERSION at the top of the repository) goes into
# the Info.plist of all three applications; PuTTY's stays in ver[].
file(STRINGS ${MACTTY_DIR}/../VERSION MACTTY_VERSION LIMIT_COUNT 1)
set_property(DIRECTORY APPEND PROPERTY
  CMAKE_CONFIGURE_DEPENDS ${MACTTY_DIR}/../VERSION)

set(MACTTY_OBJC_SOURCES
  ${MACTTY_DIR}/main.m
  ${MACTTY_DIR}/AppDelegate.m
  ${MACTTY_DIR}/Session.m
  ${MACTTY_DIR}/TerminalView.m
  ${MACTTY_DIR}/ConfigDialog.m
  ${MACTTY_DIR}/Dialogs.m
  ${MACTTY_DIR}/eventloop.m
  ${MACTTY_DIR}/platform-mac.m
  ${MACTTY_DIR}/recent.m)

add_executable(MacTTY MACOSX_BUNDLE
  ${MACTTY_OBJC_SOURCES}
  ${MACTTY_DIR}/config-mac.c
  ${MACTTY_DIR}/pageant-socket.c
  ${CMAKE_SOURCE_DIR}/unix/unicode.c
  ${CMAKE_SOURCE_DIR}/unix/printing.c
  ${CMAKE_SOURCE_DIR}/unix/config-unix.c
  ${CMAKE_SOURCE_DIR}/stubs/no-console.c
  ${MACTTY_DIR}/MacTTY.icns)
be_list(MacTTY MacTTY SSH SERIAL OTHERBACKENDS)
set_source_files_properties(${MACTTY_DIR}/MacTTY.icns
  PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
add_dependencies(MacTTY generated_licence_h)
target_include_directories(MacTTY PRIVATE ${MACTTY_DIR})
set_source_files_properties(${MACTTY_OBJC_SOURCES}
  PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(MacTTY
  guiterminal eventloop sshclient otherbackends settings
  network crypto utils ${platform_libraries}
  "-framework Cocoa" "-framework Carbon" "-framework CoreText"
  "-framework UniformTypeIdentifiers" "-framework IOKit")
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

set_target_properties(MacTTY PROPERTIES
  LINK_INTERFACE_MULTIPLICITY 2
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
  MACOSX_BUNDLE_INFO_PLIST ${MACTTY_DIR}/Info.plist.in)

# The companion tools, PuTTYgen and Pageant, are separate applications
# as they are on Windows (see README: one process per tool keeps the
# key generator's worker thread away from live sessions' random pool,
# and lets the agent outlive the terminal windows). They are built
# straight into MacTTY.app/Contents/Applications, so that MacTTY can
# start them from its menu and they travel with it.
set(MACTTY_TOOLS_DIR ${CMAKE_BINARY_DIR}/MacTTY.app/Contents/Applications)

set(MACTTYGEN_OBJC_SOURCES
  ${MACTTY_DIR}/Keygen.m
  ${MACTTY_DIR}/tools.m)
add_executable(MacTTYgen MACOSX_BUNDLE
  ${MACTTYGEN_OBJC_SOURCES}
  ${CMAKE_SOURCE_DIR}/stubs/no-timing.c
  ${CMAKE_SOURCE_DIR}/unix/keygen-noise.c
  ${CMAKE_SOURCE_DIR}/unix/no-gtk.c
  ${CMAKE_SOURCE_DIR}/unix/noise.c
  ${CMAKE_SOURCE_DIR}/unix/storage.c
  ${CMAKE_SOURCE_DIR}/sshpubk.c
  ${CMAKE_SOURCE_DIR}/sshrand.c
  ${MACTTY_DIR}/MacTTYgen.icns)
set_source_files_properties(${MACTTY_DIR}/MacTTYgen.icns
  PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
add_dependencies(MacTTYgen generated_licence_h)
target_include_directories(MacTTYgen PRIVATE ${MACTTY_DIR})
set_source_files_properties(${MACTTYGEN_OBJC_SOURCES}
  PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(MacTTYgen keygen crypto utils
  "-framework Cocoa" "-framework UniformTypeIdentifiers")
set_target_properties(MacTTYgen PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY ${MACTTY_TOOLS_DIR}
  MACOSX_BUNDLE_INFO_PLIST ${MACTTY_DIR}/MacTTYgen-Info.plist.in)
add_dependencies(MacTTY MacTTYgen)

set(PAGEANT_OBJC_SOURCES
  ${MACTTY_DIR}/Pageant.m
  ${MACTTY_DIR}/tools.m
  ${MACTTY_DIR}/eventloop.m)
add_executable(Pageant MACOSX_BUNDLE
  ${PAGEANT_OBJC_SOURCES}
  ${MACTTY_DIR}/pageant-socket.c
  ${CMAKE_SOURCE_DIR}/stubs/no-gss.c
  ${CMAKE_SOURCE_DIR}/unix/noise.c
  ${CMAKE_SOURCE_DIR}/unix/unicode.c
  ${CMAKE_SOURCE_DIR}/unix/no-gtk.c
  ${CMAKE_SOURCE_DIR}/ssh/x11fwd.c
  ${CMAKE_SOURCE_DIR}/proxy/nosshproxy.c
  ${MACTTY_DIR}/Pageant.icns)
set_source_files_properties(${MACTTY_DIR}/Pageant.icns
  PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
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
  MACOSX_BUNDLE_INFO_PLIST ${MACTTY_DIR}/Pageant-Info.plist.in)
add_dependencies(MacTTY Pageant)

set_target_properties(MacTTY MacTTYgen Pageant PROPERTIES
  MACOSX_BUNDLE_SHORT_VERSION_STRING ${MACTTY_VERSION}
  MACOSX_BUNDLE_BUNDLE_VERSION ${MACTTY_VERSION})

# PuTTY must never be built with NDEBUG; setup.cmake strips it from the C
# flags, so strip it from the Objective-C ones too.
foreach(cfg RELEASE RELWITHDEBINFO MINSIZEREL)
  string(REPLACE "-DNDEBUG" "" CMAKE_OBJC_FLAGS_${cfg}
    "${CMAKE_OBJC_FLAGS_${cfg}}")
endforeach()
