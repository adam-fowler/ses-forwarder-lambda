#!/bin/bash

cd $(dirname $0)

docker build -t swift-lambda-builder .
