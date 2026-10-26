# Spec E12: libedgerum.so, the NDK signal handler. Built by edge-rum.gradle inside the Cordova app.
cmake_minimum_required(VERSION 3.10)
project(edgerum C)
add_library(edgerum SHARED edge_rum_ndk.c)
target_link_libraries(edgerum dl)
