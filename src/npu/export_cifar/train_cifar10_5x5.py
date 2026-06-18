import argparse
import os

import torch
import torch.nn as nn
import torch.optim as optim
import torchvision
import torchvision.transforms as transforms


DEFAULT_CIFAR10_URL = "https://dataset.bj.bcebos.com/cifar/cifar-10-python.tar.gz"


class MirrorCIFAR10(torchvision.datasets.CIFAR10):
    """CIFAR-10 dataset class with an overridable download URL."""

    def __init__(self, *args, url=DEFAULT_CIFAR10_URL, **kwargs):
        self.url = url
        super().__init__(*args, **kwargs)


class TinyCIFAR10_5x5(nn.Module):
    """A very small CIFAR-10 CNN that only uses 5x5 convolution kernels."""

    def __init__(self, num_classes=10):
        super().__init__()
        self.features = nn.Sequential(
            # 3 x 32 x 32 -> 32 x 16 x 16
            nn.Conv2d(3, 32, kernel_size=5, padding=2, bias=False),
            nn.BatchNorm2d(32),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),

            # 32 x 16 x 16 -> 64 x 8 x 8
            nn.Conv2d(32, 64, kernel_size=5, padding=2, bias=False),
            nn.BatchNorm2d(64),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),
        )
        self.classifier = nn.Sequential(
            nn.AdaptiveAvgPool2d((1, 1)),
            nn.Flatten(),
            nn.Linear(64, num_classes),
        )

    def forward(self, x):
        x = self.features(x)
        return self.classifier(x)


def build_loaders(data_dir, batch_size, num_workers, cifar10_url):
    transform_train = transforms.Compose([
        transforms.RandomCrop(32, padding=4),
        transforms.RandomHorizontalFlip(),
        transforms.ToTensor(),
        transforms.Normalize((0.4914, 0.4822, 0.4465), (0.2023, 0.1994, 0.2010)),
    ])

    transform_test = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.4914, 0.4822, 0.4465), (0.2023, 0.1994, 0.2010)),
    ])

    trainset = MirrorCIFAR10(
        root=data_dir,
        train=True,
        download=True,
        transform=transform_train,
        url=cifar10_url,
    )
    testset = MirrorCIFAR10(
        root=data_dir,
        train=False,
        download=True,
        transform=transform_test,
        url=cifar10_url,
    )

    trainloader = torch.utils.data.DataLoader(
        trainset,
        batch_size=batch_size,
        shuffle=True,
        num_workers=num_workers,
        pin_memory=torch.cuda.is_available(),
    )
    testloader = torch.utils.data.DataLoader(
        testset,
        batch_size=100,
        shuffle=False,
        num_workers=num_workers,
        pin_memory=torch.cuda.is_available(),
    )
    return trainloader, testloader


def train_one_epoch(model, trainloader, criterion, optimizer, device, epoch):
    model.train()
    train_loss = 0.0
    correct = 0
    total = 0

    for batch_idx, (inputs, targets) in enumerate(trainloader):
        inputs = inputs.to(device, non_blocking=True)
        targets = targets.to(device, non_blocking=True)

        optimizer.zero_grad(set_to_none=True)
        outputs = model(inputs)
        loss = criterion(outputs, targets)
        loss.backward()
        optimizer.step()

        train_loss += loss.item()
        predicted = outputs.argmax(dim=1)
        total += targets.size(0)
        correct += predicted.eq(targets).sum().item()

    avg_loss = train_loss / (batch_idx + 1)
    acc = 100.0 * correct / total
    print(f"Epoch {epoch:03d} | Train Loss: {avg_loss:.3f} | Acc: {acc:.3f}%")


def evaluate(model, testloader, criterion, device):
    model.eval()
    test_loss = 0.0
    correct = 0
    total = 0

    with torch.no_grad():
        for batch_idx, (inputs, targets) in enumerate(testloader):
            inputs = inputs.to(device, non_blocking=True)
            targets = targets.to(device, non_blocking=True)

            outputs = model(inputs)
            loss = criterion(outputs, targets)

            test_loss += loss.item()
            predicted = outputs.argmax(dim=1)
            total += targets.size(0)
            correct += predicted.eq(targets).sum().item()

    avg_loss = test_loss / (batch_idx + 1)
    acc = 100.0 * correct / total
    print(f"           Test  Loss: {avg_loss:.3f} | Acc: {acc:.3f}%")
    return acc


def count_parameters(model):
    return sum(p.numel() for p in model.parameters())


def parse_args():
    parser = argparse.ArgumentParser(description="Tiny CIFAR-10 CNN with 5x5 convolution kernels")
    parser.add_argument("--data-dir", default="./data", help="CIFAR-10 data directory")
    parser.add_argument("--checkpoint-dir", default="./checkpoint", help="checkpoint directory")
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--lr", type=float, default=0.01)
    parser.add_argument("--num-workers", type=int, default=2)
    parser.add_argument(
        "--enable-cudnn",
        action="store_true",
        help="Enable cuDNN. It is disabled by default to avoid WSL cuDNN init errors.",
    )
    parser.add_argument(
        "--cifar10-url",
        default=DEFAULT_CIFAR10_URL,
        help="CIFAR-10 tar.gz mirror URL",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Using device: {device}")
    if device == "cuda" and not args.enable_cudnn:
        torch.backends.cudnn.enabled = False
        print("cuDNN disabled; using CUDA without cuDNN for better WSL compatibility.")
    print(f"CIFAR-10 URL: {args.cifar10_url}")

    trainloader, testloader = build_loaders(
        args.data_dir,
        args.batch_size,
        args.num_workers,
        args.cifar10_url,
    )

    model = TinyCIFAR10_5x5().to(device)
    print(model)
    print(f"Total parameters: {count_parameters(model):,}")

    criterion = nn.CrossEntropyLoss()
    optimizer = optim.SGD(model.parameters(), lr=args.lr, momentum=0.9, weight_decay=5e-4)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)

    os.makedirs(args.checkpoint_dir, exist_ok=True)
    best_acc = 0.0

    for epoch in range(args.epochs):
        train_one_epoch(model, trainloader, criterion, optimizer, device, epoch)
        acc = evaluate(model, testloader, criterion, device)
        scheduler.step()

        if acc > best_acc:
            best_acc = acc
            ckpt_path = os.path.join(args.checkpoint_dir, "tiny_cifar10_5x5.pth")
            torch.save({
                "model": model.state_dict(),
                "best_acc": best_acc,
                "epoch": epoch,
                "model_name": "TinyCIFAR10_5x5",
            }, ckpt_path)
            print(f"           Saved best checkpoint: {ckpt_path}")

    print(f"Training finished. Best accuracy: {best_acc:.3f}%")


if __name__ == "__main__":
    main()


