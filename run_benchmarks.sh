#!/bin/bash
set -e

# Make sure flutter linux desktop is enabled
cd example
flutter config --enable-linux-desktop > /dev/null 2>&1
cd ..

# Run the python script which acts as the orchestrator
python3 benchmark.py
