#!/usr/bin/env bash

set -euo pipefail

experiment_path=$1
sweep_cfg_folder=${2:-""}

# constants
train_folder="$experiment_path/train"
eval_folder="$experiment_path/eval"

# how many started/finished?
num_started=$(ls $train_folder | wc -l)
num_finished=$(ls $eval_folder/*/valid.eval.score | wc -l)

if [ -z "${sweep_cfg_folder}" ]; then
    echo "Experiment: ${experiment_path}"
    echo "Num started: ${num_started}"
    echo "Num finished: ${num_finished}"
else
    n_total_configs=$(cat ${sweep_cfg_folder}/*.tsv | wc -l)
    echo "Experiment: ${experiment_path}"
    echo "Num started: ${num_started} / ${n_total_configs}"
    echo "Num finished: ${num_finished} / ${n_total_configs}"
fi