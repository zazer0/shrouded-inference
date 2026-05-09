"""Download an EquiformerV2 checkpoint from the fairchem model registry."""
import argparse
import pathlib

from fairchem.core.models.model_registry import model_name_to_local_file

DEFAULT_MODEL = "EquiformerV2-31M-S2EF-OC20-All+MD"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model-name", default=DEFAULT_MODEL,
        help=f"Model registry name (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--output-dir", default="model_artifacts/equiformer",
        help="Directory for the checkpoint (default: model_artifacts/equiformer)",
    )
    args = parser.parse_args()

    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    checkpoint_path = model_name_to_local_file(args.model_name, local_cache=str(output_dir))
    print(f"Downloaded: {checkpoint_path}")


if __name__ == "__main__":
    main()
