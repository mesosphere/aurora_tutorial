Mesosphere Aurora Tutorial
==========================
This repo contains support files for the [Mesosphere Aurora Tutorial][1].

# ACCP: Aurora Cluster Configuration Program

## Usage

See: `./accp.bash --help`

## Sample Configuration File

```
# Mesos Master IP (external)   Mesos Master IP (internal)
54.168.1.10                    192.168.1.10

# Master and Slave sections must be seperated by a newline.
# Leading and trailing blanks are okay.
# Comments are from '#' to end-of-line.
# Mesos Slave IP's (external)
54.168.1.11
54.168.1.12
54.168.1.13
```

[1]: http://mesosphere.io/learn
