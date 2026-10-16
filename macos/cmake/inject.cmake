# Injected into PuTTY's top-level project() through CMAKE_PROJECT_INCLUDE
# (see build.sh). PuTTY's CMake must stay the top-level project because it
# refers to CMAKE_SOURCE_DIR throughout, so instead of wrapping it we hook
# our Cocoa front end in at the end of its top-level CMakeLists.txt.

# project() is also called from subdirectories (doc/); act only once, at
# the top level.
if(NOT CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR)
  return()
endif()

# MACTTY_DIR is macos/, the root of the front end's sources.
get_filename_component(MACTTY_DIR ${CMAKE_CURRENT_LIST_DIR} DIRECTORY)

# Every PuTTY source file sees MACTTY, which selects the Cocoa profile in
# unix/platform.h (clipboard semantics, OS X meta-key settings, ...).
add_compile_definitions(MACTTY)

# The GTK front end is replaced by ours, so never look for GTK.
set(PUTTY_GTK_VERSION NONE CACHE STRING "" FORCE)

enable_language(OBJC)

# Subdirectories cannot be added from a deferred call, so the target
# definitions are included into the top-level directory instead.
cmake_language(DEFER CALL include ${MACTTY_DIR}/cmake/targets.cmake)
