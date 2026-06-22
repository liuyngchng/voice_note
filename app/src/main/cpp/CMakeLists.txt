cmake_minimum_required(VERSION 3.22.1)
project("llama_jni")

# llama.cpp integration is optional — clone llama.cpp into this directory to enable
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/CMakeLists.txt")
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp ${CMAKE_CURRENT_BINARY_DIR}/llama.cpp)
    add_library(llama_jni SHARED llama_jni.c)
    target_link_libraries(llama_jni llama log)
    target_compile_definitions(llama_jni PRIVATE LLAMA_AVAILABLE=1)
else()
    # Stub library — offline LLM unavailable until llama.cpp source is added
    add_library(llama_jni SHARED llama_jni_stub.c)
    target_link_libraries(llama_jni log)
    target_compile_definitions(llama_jni PRIVATE LLAMA_AVAILABLE=0)
endif()
