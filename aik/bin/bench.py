#!/usr/bin/env python3
import json
import sys
import argparse
import subprocess
import toml
import os

# Hardcode the limits from the README
MAX_TX_EXECUTION_CPU = 10_000_000_000
MAX_TX_EXECUTION_MEMORY = 14_000_000
MAX_BLOCK_EXECUTION_CPU = 20_000_000_000
MAX_BLOCK_EXECUTION_MEMORY = 62_000_000

def run_single_benchmark(max_cheques, max_size, output_dir):
    toml_path = 'aiken.toml'
    if not os.path.exists(toml_path):
        print(f"Error: {toml_path} not found in current directory.")
        sys.exit(1)

    # Load and modify aiken.toml
    config = toml.load(toml_path)
    original_max_cheques = config.get('config', {}).get('testing', {}).get('max_cheques')

    try:
        config.setdefault('config', {}).setdefault('testing', {})['max_cheques'] = max_cheques
        with open(toml_path, 'w') as f:
            toml.dump(config, f)

        # Define output files
        base_name = f"cheques-{max_cheques}"
        raw_file = os.path.join(output_dir, f"{base_name}.json")
        perc_file = os.path.join(output_dir, f"{base_name}-perc.json")
        max_channels_file = os.path.join(output_dir, f"{base_name}-max-channels.json")

        # Run aiken bench command
        bench_cmd = f"aiken bench . 'testing' --max-size {max_size} | jq"
        with open(raw_file, 'w') as f:
            subprocess.run(bench_cmd, shell=True, check=True, stdout=f)

        with open(raw_file, 'r') as f:
            raw_data = json.load(f)

            # Process to percentiles
            perc_data = compute_precentage(raw_data)

            with open(perc_file, 'w') as f:
                json.dump(perc_data, f, indent=4)

        # Find and save max safe sizes per benchmark
        max_safes = find_max_safe_size(perc_data)

        with open(max_channels_file, 'w') as f:
            json.dump(max_safes, f, indent=4)

        print(f"Processed benchmark for max_cheques={max_cheques}, saved to {output_dir}")

    finally:
        # Restore original max_cheques
        if original_max_cheques is not None:
            config['config']['testing']['max_cheques'] = original_max_cheques
        else:
            config['config']['testing'].pop('max_cheques', None)
        with open(toml_path, 'w') as f:
            toml.dump(config, f)

def compute_and_print_maxima(perc_data):
    # Find max safe sizes
    max_safes = find_max_safe_size(perc_data)

    # Print to console
    print("Max safe sizes per benchmark:")
    for name, size in max_safes.items():
        print(f"{name}: {size}")

def compute_precentage(bench_data):
    # deep copy
    perc_data = json.loads(json.dumps(bench_data))

    # Compute percentages in memory (adapted from compute_precentage)
    for benchmark in perc_data['benchmarks']:
        for measure in benchmark['measures']:
            measure['memory'] = (measure['memory'] / MAX_TX_EXECUTION_MEMORY) * 100
            measure['cpu'] = (measure['cpu'] / MAX_TX_EXECUTION_CPU) * 100

    # Print the computed percentages to console
    print("Computed percentages for benchmarks:")
    for benchmark in perc_data['benchmarks']:
        print(f"Benchmark: {benchmark['name']}")
        for measure in benchmark['measures']:
            print(f"  Size: {measure['size']}, Memory%: {measure['memory']:.2f}, CPU%: {measure['cpu']:.2f}")
    return perc_data

def find_max_safe_size(perc_data):
    results = {}
    for benchmark in perc_data['benchmarks']:
        name = benchmark['name']
        max_size = 0
        measures = sorted(benchmark['measures'], key=lambda m: m['size'])
        for measure in measures:
            if measure['memory'] < 100 and measure['cpu'] < 100:
                max_size = measure['size']
            else:
                break  # Stop at first unsafe size, assuming sizes are incremental
        results[name] = max_size
    return results

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Benchmark runner with commands.")
    subparsers = parser.add_subparsers(dest='command', required=True, help="Available commands")

    # 'suite' command (no additional args)
    suite_parser = subparsers.add_parser('suite', help="Run a suite of benchmarks with predefined parameters")
    suite_parser.add_argument('--output-dir', type=str, default='.', help="Directory to save output files")
    suite_parser.add_argument('--max-size', type=int, default=None, help="Max size for aiken bench command, overrides hardcoded values for all suite runs if provided")

    # 'single' command (existing args)
    single_parser = subparsers.add_parser('single', help="Run a single benchmark with specified parameters")
    single_parser.add_argument('--max-cheques', type=int, required=True, help="Value to set for max_cheques in aiken.toml")
    single_parser.add_argument('--output-dir', type=str, default='.', help="Directory to save output files")
    single_parser.add_argument('--max-size', type=int, default=50, help="Max size for aiken bench command (default: 50)")

    # 'maxima' command
    maxima_parser = subparsers.add_parser('maxima', help="Compute and print maxima from a raw JSON file")
    maxima_parser.add_argument('input_file', type=str, help="Path to the raw JSON benchmark file")

    args = parser.parse_args()

    if args.command == 'suite':
        # Predefined runs: (max_cheques, max_size)
        runs = [(1, 60), (5, 40), (10, 30), (20, 30)]
        if args.max_size is not None:
            runs = [(cheques, args.max_size) for cheques, _ in runs]
        for max_cheques, max_size in runs:
            run_single_benchmark(max_cheques, max_size, args.output_dir)

    elif args.command == 'single':
        run_single_benchmark(args.max_cheques, args.max_size, args.output_dir)

    elif args.command == 'maxima':
        with open(args.input_file, 'r') as f:
            raw_data = json.load(f)
        perc_data = compute_precentage(raw_data)
        compute_and_print_maxima(perc_data)
