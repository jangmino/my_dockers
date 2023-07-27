#!/bin/bash

# 최신 버전: 2023-07-27
docker build -t jangminnature/qlora:v1.2-23.05-py3 --build-arg UID=$UID --build-arg USER_NAME=$USER -f Dockerfile.qlora.v1.2 ./