import json
import logging
import pathlib

logger = logging.getLogger(__name__)


def model_fn(model_dir: str):
    """Load an OCPCalculator from the .pt checkpoint found in model_dir.

    Returns None on failure so the server stays healthy for /ping even when the
    checkpoint is missing, malformed, or fairchem-core fails to import.
    """
    try:
        from fairchem.core import OCPCalculator
    except Exception as exc:
        logger.warning("fairchem.core import failed: %s — running in degraded mode", exc)
        return None

    model_dir_path = pathlib.Path(model_dir)
    checkpoints = list(model_dir_path.glob("*.pt"))
    if not checkpoints:
        logger.warning("No .pt checkpoint found in %s — running in degraded mode", model_dir)
        return None
    if len(checkpoints) > 1:
        logger.warning("Multiple .pt checkpoints in %s — running in degraded mode", model_dir)
        return None

    checkpoint_path = checkpoints[0]
    try:
        calculator = OCPCalculator(checkpoint_path=str(checkpoint_path), cpu=False)
        return calculator
    except Exception as exc:
        logger.warning("OCPCalculator failed to load %s: %s — running in degraded mode", checkpoint_path, exc)
        return None


def input_fn(request_body, content_type):
    """Parse a JSON request body into an ASE Atoms object.

    Expected JSON schema:
        {
            "positions": [[x, y, z], ...],
            "numbers":   [atomic_number, ...],
            "cell":      [[a1, a2, a3], [b1, b2, b3], [c1, c2, c3]],
            "pbc":       [bool, bool, bool]
        }
    """
    import numpy as np
    from ase import Atoms

    if content_type != "application/json":
        raise ValueError(
            f"Unsupported content type: {content_type!r}. Expected 'application/json'."
        )

    if isinstance(request_body, bytes):
        request_body = request_body.decode("utf-8")

    payload = json.loads(request_body)

    atoms = Atoms(
        numbers=payload["numbers"],
        positions=np.array(payload["positions"], dtype=np.float64),
        cell=np.array(payload["cell"], dtype=np.float64),
        pbc=payload["pbc"],
    )
    return atoms


def predict_fn(input_data, model) -> dict:
    """Run energy and force inference on the provided Atoms object."""
    if model is None:
        raise RuntimeError("Model is not loaded — checkpoint missing or failed to initialise")
    input_data.calc = model
    energy = float(input_data.get_potential_energy())
    forces = input_data.get_forces().tolist()
    return {"energy": energy, "forces": forces}


def output_fn(prediction: dict, accept: str) -> str:
    """Serialise the prediction dict to a JSON string."""
    return json.dumps({"energy": prediction["energy"], "forces": prediction["forces"]})
