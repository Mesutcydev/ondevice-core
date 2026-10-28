add_library(ODMiniCPM SHARED ODMiniCPM.cpp ODMiniCPM.h)
target_link_libraries(ODMiniCPM PRIVATE llama mtmd)
target_compile_features(ODMiniCPM PRIVATE cxx_std_17)
target_compile_options(ODMiniCPM PRIVATE -fvisibility=hidden)
target_link_options(ODMiniCPM PRIVATE "LINKER:-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exports.txt")
target_compile_definitions(ggml-metal PRIVATE GGMLMetalClass=ODMiniCPMMetalClass)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(OD_FRAMEWORK_MINIMUM_OS_KEY MinimumOSVersion)
    set(OD_FRAMEWORK_PLATFORM iPhoneOS)
elseif(CMAKE_CXX_COMPILER_TARGET MATCHES "-macabi$")
    set(OD_FRAMEWORK_MINIMUM_OS_KEY MinimumOSVersion)
    set(OD_FRAMEWORK_PLATFORM MacOSX)
else()
    set(OD_FRAMEWORK_MINIMUM_OS_KEY LSMinimumSystemVersion)
    set(OD_FRAMEWORK_PLATFORM MacOSX)
endif()
set_target_properties(ODMiniCPM PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    MACOSX_FRAMEWORK_IDENTIFIER com.ondevice.minicpm47
    MACOSX_FRAMEWORK_BUNDLE_NAME ODMiniCPM
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING 1.0.0
    MACOSX_FRAMEWORK_BUNDLE_VERSION 1
    MACOSX_FRAMEWORK_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    VERSION 1.0.0
    SOVERSION 1
    PUBLIC_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/ODMiniCPM.h"
)
