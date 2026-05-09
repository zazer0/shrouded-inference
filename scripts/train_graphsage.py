import argparse
import os
import pickle

import torch
import torch.nn.functional as F
from torch_geometric.datasets import Planetoid
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


def train(model, data, optimizer):
    model.train()
    optimizer.zero_grad()
    out = model(data.x, data.edge_index)
    loss = F.nll_loss(out[data.train_mask], data.y[data.train_mask])
    loss.backward()
    optimizer.step()
    return loss.item()


def main():
    parser = argparse.ArgumentParser(description="Train a GraphSAGE model on Cora")
    parser.add_argument(
        "--output-dir",
        default="model_artifacts/graphsage",
        help="Directory to save model.pt and data.pkl",
    )
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    dataset = Planetoid(root="/tmp/cora", name="Cora")
    data = dataset[0]

    model = GraphSAGE()
    optimizer = torch.optim.Adam(model.parameters(), lr=0.01)

    for epoch in range(1, 201):
        loss = train(model, data, optimizer)
        if epoch % 20 == 0:
            print(f"Epoch {epoch:03d}, Loss: {loss:.4f}")

    torch.save(model.state_dict(), os.path.join(args.output_dir, "model.pt"))

    with open(os.path.join(args.output_dir, "data.pkl"), "wb") as f:
        pickle.dump(data, f)

    print(f"Saved model.pt and data.pkl to {args.output_dir}")


if __name__ == "__main__":
    main()
