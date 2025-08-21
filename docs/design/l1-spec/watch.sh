#!/usr/bin/env bash

# Infinite loop to monitor changes
while true; do
    inotifywait -e modify *.puml
    echo "Detected changes in one of the files..."
    for file in *.puml; do
        plantuml -tsvg $file
    done
    echo "Generated SVG files..."
    firefox *.svg &
done

