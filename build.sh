#!/bin/bash

# 최신 버전: 2023-11-30
docker build -t jangminnature/peft:v1.2dev-torch2.1-cu121 --build-arg UID=$UID --build-arg USER_NAME=$USER -f Dockerfile.peft.v1.2dev ./

# 최신 버전: 2023-10-06
# docker build -t jangminnature/peft:v1.1dev-torch2.1-cu118 --build-arg UID=$UID --build-arg USER_NAME=$USER -f Dockerfile.peft.v1.1dev ./

# 최신 버전: 2023-09-11
# docker build -t jangminnature/peft:v1.0-23.08-py3 --build-arg UID=$UID --build-arg USER_NAME=$USER -f Dockerfile.peft.v1.1 ./

# 최신 버전: 2023-09-07
# docker build -t jangminnature/peft:v1.0-23.05-py3 --build-arg UID=$UID --build-arg USER_NAME=$USER -f Dockerfile.peft.v1.0 ./

# QLoRa: 2023-07-27
# docker build -t jangminnature/qlora:v1.2-23.05-py3 --build-arg UID=$UID --build-arg USER_NAME=$USER -f Dockerfile.qlora.v1.2 ./
