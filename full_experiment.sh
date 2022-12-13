#!/usr/bin/env bash

# Complete experiment sequence
set -eox pipefail

# Constants
config_file=$1
should_confirm=${2:-"true"}
append_meta=${3:-"false"}

cuda_visible=${CUDA_VISIBLE_DEVICES:-""}

# TODO: Change this
check_these_vars=(
    "randseg_experiment_name"
    "randseg_model_name"
    "randseg_random_seed"
    "randseg_pick_randomly"
    "randseg_num_merges"
    "randseg_root_folder"
    "randseg_raw_data_folder"
    "randseg_binarized_data_folder"
    "randseg_checkpoints_folder"
    "randseg_source_language"
    "randseg_target_language"
)

# Step 0: Dependencies
check_deps() {
    echo "❗  Checking dependencies..."
    while read -r dep; do
        test -z "$(which $dep)" &&
            echo "Missing dependency: ${dep}" &&
            exit 1 || echo "Found ${dep} ➡  $(which $dep)"
    done <requirements_external.txt
    echo "✅  Dependencies seem OK"
}

fill_optionals() {
    . config/default_hparams.sh
}

add_metadata() {
    local experiment_name=$1
    echo "👷 TODO❗" && exit 1
}

create_temp_folder() {
    local default_prefix=$(
        grep -q "^hpcc" &&
            echo "$WORK/$(whoami)" ||
            echo "/tmp"
    )
    local prefix=${1:-"${default_prefix}"}
    local template=${2:-"some_temp_folder"}
    mktemp -d -p "${prefix}" "${template}"
}

check_env() {
    echo "❗ Checking environment..."

    # First check mandatory variables
    missing=false
    for var in "${check_these_vars[@]}"; do
        eval "test -z \$$var" &&
            echo "Missing variable: $var" &&
            missing="true"
    done
    test "$missing" = "true" && exit 1

    # Then check and fill optionals
    fill_optionals

    echo "✅  Environment seems OK"
}

create_experiment() {
    echo "❗ Creating experiment..."

    prepx create \
        --with-tensorboard --with-supplemental-data \
        --root-folder="${randseg_root_folder}" \
        --experiment-name="${randseg_experiment_name}" \
        --train-name="${randseg_model_name}" \
        --raw-data-folder="${randseg_raw_data_folder}" \
        --checkpoints-folder="${randseg_checkpoints_folder}" \
        --binarized-data-folder="${randseg_binarized_data_folder}"

    echo "✅  Done!"
}

preprocess() {
    echo "❗ Preprocessing..."

    . scripts/bpe_functions.sh

    train_folder="${randseg_root_folder}/${randseg_experiment_name}/train/${randseg_model_name}"
    data_folder="${train_folder}/raw_data"
    binarized_data_folder="${train_folder}/binarized_data"
    supplemental_data_folder="${train_folder}/supplemental_data"

    env | rg '^randseg' | tee ${supplemental_data_folder}/relevant_environment_variables.txt

    src=${randseg_source_language}
    tgt=${randseg_target_language}

    # Train BPE/RandBPE using the train seg
    for language in "${src}" "${tgt}"; do
        codes=${supplemental_data_folder}/${language}.bpe.codes

        echo "[${language}] Learning BPE on train..."
        learn_bpe \
            "${data_folder}/train.${language}" \
            "${randseg_num_merges}" \
            "${codes}" \
            "${randseg_pick_randomly}" \
            "${randseg_random_seed}"

        for split in "train" "dev" "test"; do
            echo "[${language}, ${split}] Segmenting with BPE..."
            text_file="${data_folder}/${split}.${language}"
            out_file=${supplemental_data_folder}/${split}.bpe.${language}
            apply_bpe \
                "${text_file}" \
                "${codes}" \
                "${out_file}"
        done
        vocab_file=${supplemental_data_folder}/bpe_vocab.${language}
        train_bpe_segmented="${supplemental_data_folder}/train.bpe.${language}"
        get_vocab "${train_bpe_segmented}" "${vocab_file}"
    done

    fairseq-preprocess \
        --source-lang "${src}" --target-lang "${tgt}" \
        --trainpref "${supplemental_data_folder}/train.bpe" \
        --validpref "${supplemental_data_folder}/dev.bpe" \
        --testpref "${supplemental_data_folder}/test.bpe" \
        --destdir "${randseg_binarized_data_folder}" \
        --workers "${randseg_num_parallel_workers}"

    echo "✅ Done!"

}

train() {
    echo "❗ Starting training..."

    train_folder="${randseg_root_folder}/${randseg_experiment_name}/train/${randseg_model_name}"
    data_folder="${train_folder}/raw_data"
    binarized_data_folder="${train_folder}/binarized_data"
    checkpoints_folder="${train_folder}/checkpoints"
    supplemental_data_folder="${train_folder}/supplemental_data"
    train_log_file="${train_folder}/train.log"

    cpu_gpu_fp16_flag=$(test -z "${cuda_visible}" && echo "--cpu" || echo "--fp16")

    src=${randseg_source_language}
    tgt=${randseg_target_language}

    warmup_updates_flag="--warmup-updates=${randseg_warmup_updates}"

    if [[ "${LR_SCHEDULER}" == "inverse_sqrt" ]]; then
        warmup_init_lr_flag="--warmup-init-lr=${randseg_warmup_init_lr}"
    else
        warmup_init_lr_flag=""
    fi

    fairseq-train \
        "${binarized_data_folder}" \
        ${cpu_gpu_fp16_flag} ${warmup_updates_flag} ${warmup_init_lr_flag} \
        --save-dir="${checkpoints_folder}" \
        --source-lang="${src}" \
        --target-lang="${tgt}" \
        --log-format="json" \
        --seed="${randseg_random_seed}" \
        --patience=${randseg_patience} \
        --arch=transformer \
        --attention-dropout="${randseg_p_dropout}" \
        --activation-dropout="${randseg_p_dropout}" \
        --activation-fn="${randseg_activation_fn}" \
        --encoder-embed-dim="${randseg_encoder_embedding_dim}" \
        --encoder-ffn-embed-dim="${randseg_encoder_hidden_size}" \
        --encoder-layers="${randseg_encoder_layers}" \
        --encoder-attention-heads="${randseg_encoder_attention_heads}" \
        --encoder-normalize-before \
        --decoder-embed-dim="${randseg_decoder_embedding_dim}" \
        --decoder-ffn-embed-dim="${randseg_decoder_hidden_size}" \
        --decoder-layers="${randseg_decoder_layers}" \
        --decoder-attention-heads="${randseg_decoder_attention_heads}" \
        --decoder-normalize-before \
        --share-decoder-input-output-embed \
        --criterion="${randseg_criterion}" \
        --label-smoothing="${randseg_label_smoothing}" \
        --optimizer="${randseg_optimizer}" \
        --lr="${randseg_lr}" \
        --lr-scheduler="${randseg_lr_scheduler}" \
        --clip-norm="${randseg_clip_norm}" \
        --batch-size="${randseg_batch_size}" \
        --max-update="${randseg_max_update}" \
        --save-interval="${randseg_save_interval}" \
        --validate-interval-updates="${randseg_validate_interval_updates}" \
        --adam-betas '(0.9, 0.98)' --update-freq="${randseg_update_freq}" \
        --no-epoch-checkpoints \
        --max-source-positions=2500 --max-target-positions=2500 \
        --skip-invalid-size-inputs-valid-test |
        tee "${train_log_file}"

    echo "✅ Done training..."
    echo "✅ Done!"
}

evaluate() {
    local split=$1
    echo "❗ [${split}] Evaluating..."

    echo "✅ Done!"

}

main() {
    local config=$1
    local should_confirm_commands=${2:-"true"}

    source "${config}"

    confirm_commands_flag=$(
        test "${should_confirm_commands}" = "false" &&
            echo "cat" ||
            echo "fzf --sync --multi"
    )

    echo check_deps check_env create_experiment preprocess train evaluate |
        tr " " "\n" |
        ${confirm_commands_flag} |
        while read command; do
            if [ "$command" = "evaluate" ]; then
                for split in "dev" "test"; do evaluate $split; done
            else
                $command
            fi
        done
}

main "${config_file}" "${should_confirm}"

# IDEAS / TODO
# - environment should be printed into supplemental data
# - binarized data folder creation needs to happen
