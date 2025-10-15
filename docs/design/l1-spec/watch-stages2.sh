#!/usr/bin/env bash

while true; do
    inotifywait -e modify stages2.puml
    echo "Detected changes in stages2.puml..."
    plantuml -tsvg stages2.puml
    echo "Generating SVG file..."
    # firefox stages.svg &
done

