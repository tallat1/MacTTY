# The MacTTY application. Included at the end of PuTTY's top-level
# CMakeLists.txt by inject.cmake, so all of PuTTY's libraries and helper
# functions (be_list etc.) are available here.

set(MACTTY_OBJC_SOURCES
  ${MACTTY_DIR}/main.m
  ${MACTTY_DIR}/AppDelegate.m
  ${MACTTY_DIR}/Session.m
  ${MACTTY_DIR}/TerminalView.m
  ${MACTTY_DIR}/ConfigDialog.m
  ${MACTTY_DIR}/Dialogs.m
  ${MACTTY_DIR}/eventloop.m
  ${MACTTY_DIR}/platform-mac.m)

add_executable(MacTTY MACOSX_BUNDLE
  ${MACTTY_OBJC_SOURCES}
  ${MACTTY_DIR}/config-mac.c
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
  "-framework UniformTypeIdentifiers")
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

# PuTTY must never be built with NDEBUG; setup.cmake strips it from the C
# flags, so strip it from the Objective-C ones too.
foreach(cfg RELEASE RELWITHDEBINFO MINSIZEREL)
  string(REPLACE "-DNDEBUG" "" CMAKE_OBJC_FLAGS_${cfg}
    "${CMAKE_OBJC_FLAGS_${cfg}}")
endforeach()
