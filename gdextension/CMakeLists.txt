cmake_minimum_required(VERSION 3.22)

project(silent_verse_particles LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# godot-cpp：目标 Godot 4.7，编辑器构建（headless/editor 都可加载）
set(GODOTCPP_API_VERSION "4.7" CACHE STRING "" FORCE)
set(GODOTCPP_TARGET "editor" CACHE STRING "" FORCE)
set(GODOTCPP_ENABLE_TESTING OFF CACHE BOOL "" FORCE)

add_subdirectory(
    ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/godot-cpp
    ${CMAKE_BINARY_DIR}/godot-cpp
)

add_library(silent_verse_particles SHARED
    src/register_types.cpp
    src/soil_dem_kernel.cpp
)

target_include_directories(silent_verse_particles PRIVATE src)
target_link_libraries(silent_verse_particles PRIVATE godot-cpp)

get_target_property(GODOTCPP_SUFFIX godot-cpp GODOTCPP_SUFFIX)

set(OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../bin")
set_target_properties(silent_verse_particles PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    POSITION_INDEPENDENT_CODE ON
    PREFIX "lib"
    OUTPUT_NAME "silent_verse_particles${GODOTCPP_SUFFIX}"
    RUNTIME_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
    PDB_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
)
