#!usr/bin/bash
echo "Running slangc"
slangc world.slang -entry vsMain -entry psMain \
       -target spirv -o bin/world.spv
