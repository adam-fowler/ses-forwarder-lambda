#!/bin/bash

here=$(dirname $0)

echo "-------------------------------------------------------------------------"
echo "building docker image swift-lambda-builder"
echo "-------------------------------------------------------------------------"
docker build -t swift-lambda-builder $here
