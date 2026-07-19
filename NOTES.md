1. Create S3 bucket with fastq files
2. Create VM
3. Install required deps
4. s3 cp in assets
5. get the database
6. run kraken
7. wait a while

Install deps

sudo apt update
sudo apt install -y awscli make tmux g++ zlib1g-dev
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip
sudo ./aws/install

curl -LO https://github.com/DerrickWood/kraken2/archive/refs/tags/v2.17.1.tar.gz
tar -xzf v2.17.1.tar.gz
```

Database

```
aws s3 cp --no-sign-request \
  s3://genome-idx/kraken/k2_standard_20260626.tar.gz .
# or

curl https://genome-idx.s3.amazonaws.com/kraken/k2_standard_20260626.tar.gz
```

Data

```
aws s3 sync lcm-bioinformatics-db-058664348318-ap-southeast-2-an/* data
```

Run it 

```
kraken2 \
  --db ./k2_standard_20260626 \
  --paired \
  --threads 16 \
  --report k2_standard_20260626_sample_report \
  --output k2_standard_20260626_sample.kraken \
  ./non_host.fastq.1.gz \
  ./non_host.fastq.2.gz
```

Overall


```
#!/bin/bash

# 1. Update and Install Essential Tools (AWS CLI, Tmux)
sudo apt update
sudo apt install -y awscli tmux make g++ zlib libz-dev pigz curl

# 2. Configure AWS CLI (You'll need to configure this with your credentials!)
aws configure  # Follow the prompts to enter your Access Key ID, Secret Access Key, Region, and Output Format.

# 3. Download Kraken2
curl -LO https://github.com/DerrickWood/kraken2/archive/refs/tags/v2.17.1.tar.gz
tar -xzf v2.17.1.tar.gz

# 4. Install Kraken2 (Multiple attempts, consolidating)
cd kraken2-2.17.1/
sudo ./install_kraken2.sh /usr/local/bin  # First attempt at installation
mkdir -p ~/.local/bin # Create the directory if it doesn't exist
sudo ./install_kraken2.sh ~/.local/bin   # Install to user local bin

# 5. Set up PATH (Important for running Kraken2)
export PATH="$HOME/.local/bin:$PATH"  # Add .local/bin to your path

# 6. Download and Extract Kraken2 Database (Standard DB)
aws s3 cp --no-sign-request   s3://genome-idx/kraken/k2_standard_20260626.tar.gz database
cd database
tar -xzvf  k2_standard_20260626.tar.gz

# 7. Create a script to run Kraken2 (Based on the history)
# runkrakren.sh

chmod +x runkraken.sh

# 8. Run Kraken2 in the background (nohup)
nohup time ./runkraken.sh &
```

## Scripts

```
kraken2 \
  --db ./database \
  --paired \
  --threads 16 \
  --report k2_standard_20260626_sample_report \
  --output k2_standard_20260626_sample.kraken \
  ./data/non_host.fastq.1.gz \
  ./data/non_host.fastq.2.gz
```