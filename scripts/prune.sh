#!/bin/bash

docker stop $(docker ps -q)
docker container prune