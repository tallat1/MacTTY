# Application icons. Each application keeps its icon as an Icon Composer
# document next to its sources (macos/<App>/<App>.icon). actool turns it
# into an asset catalog holding the layered Liquid Glass icon with its
# dark, clear and tinted variants for macOS 26 and later, and the
# flattened images earlier systems show; Info.plist names the icon in
# CFBundleIconName. This needs actool from Xcode 26 or later; without it
# the applications are built with no icon of their own.

execute_process(COMMAND xcrun --find actool
  OUTPUT_VARIABLE MACTTY_ACTOOL OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET)
if(NOT MACTTY_ACTOOL)
  message(WARNING "actool not found (Xcode 26 or later is needed): "
    "MacTTY, MacTTYgen and Pageant will have no icons")
endif()

# Compile <target>.icon and put the results in the bundle's Resources.
function(mactty_app_icon target)
  if(NOT MACTTY_ACTOOL)
    return()
  endif()
  set(icon ${MACTTY_DIR}/${target}/${target}.icon)
  set(out ${CMAKE_BINARY_DIR}/icons/${target})
  file(GLOB_RECURSE icon_files ${icon}/*)
  add_custom_command(
    OUTPUT ${out}/Assets.car ${out}/${target}.icns
    COMMAND ${CMAKE_COMMAND} -E make_directory ${out}
    COMMAND ${MACTTY_ACTOOL} ${icon} --compile ${out}
      --app-icon ${target} --include-all-app-icons
      --output-partial-info-plist ${out}/partial.plist
      --platform macosx --target-device mac
      --minimum-deployment-target ${CMAKE_OSX_DEPLOYMENT_TARGET}
      --enable-on-demand-resources NO --development-region en
      --errors --warnings --output-format human-readable-text
    DEPENDS ${icon_files}
    COMMENT "Compiling the ${target} icon"
    VERBATIM)
  target_sources(${target} PRIVATE ${out}/Assets.car ${out}/${target}.icns)
  set_source_files_properties(${out}/Assets.car ${out}/${target}.icns
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
endfunction()
