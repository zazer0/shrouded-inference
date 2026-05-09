import json
import os
import pickle

import torch
import torch.nn.functional as F
from torch_geometric.nn import SAGEConv


class GraphSAGE(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = SAGEConv(1433, 64)
        self.conv2 = SAGEConv(64, 7)

    def forward(self, x, edge_index):
        x = self.conv1(x, edge_index)
        x = F.relu(x)
        x = self.conv2(x, edge_index)
        return F.log_softmax(x, dim=1)


def model_fn(model_dir):
    model = GraphSAGE()
    model.load_state_dict(
        torch.load(os.path.join(model_dir, "model.pt"), map_location="cpu")
    )
    model.eval()

    with open(os.path.join(model_dir, "data.pkl"), "rb") as f:
        data = pickle.load(f)

    return model, data


def input_fn(request_body, content_type):
    if content_type != "application/json":
        raise ValueError(f"Unsupported content type: {content_type}")
    payload = json.loads(request_body)
    return payload["node_indices"]


def predict_fn(input_data, model_and_data):
    model, data = model_and_data
    node_indices = torch.tensor(input_data, dtype=torch.long)

    with torch.no_grad():
        out = model(data.x, data.edge_index)

    predictions = out[node_indices].argmax(dim=1).tolist()
    return predictions


def output_fn(prediction, accept):
    return json.dumps({"predictions": prediction}), "application/json"
