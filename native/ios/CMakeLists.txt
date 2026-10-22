# iPhone build of the DJ engine as one static library (built in CI on a Mac).
cmake_minimum_required(VERSION 3.22)
project(dj_engine_ios LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

get_filename_component(ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(ENGINE_DIR "${ROOT}/native/engine")
set(DR_LIBS "${ROOT}/third_party/dr_libs")
set(STRETCH_DIR "${ROOT}/third_party/signalsmith-stretch")
set(LINEAR_DIR "${ROOT}/third_party/signalsmith-linear")
set(QM_DSP_DIR "${ROOT}/third_party/qm-dsp")

add_subdirectory("${QM_DSP_DIR}" qm-dsp-build)
include("${ROOT}/third_party/opus_stack.cmake")

add_library(dj_engine STATIC
  "${ENGINE_DIR}/dj_engine.cpp"
  "${ENGINE_DIR}/last_error.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/ios_session.mm"
)
set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/ios_session.mm" PROPERTIES COMPILE_FLAGS "-fobjc-arc")
target_compile_definitions(dj_engine PRIVATE _USE_MATH_DEFINES)
target_compile_options(dj_engine PRIVATE -fexceptions -fvisibility=default)
target_include_directories(dj_engine PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/shim"
  "${ENGINE_DIR}"
  "${DR_LIBS}"
  "${STRETCH_DIR}"
  "${LINEAR_DIR}/include"
  "${QM_DSP_DIR}"
)
target_link_libraries(dj_engine PUBLIC qm_dsp opusfile)
