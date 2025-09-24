# PSMD Pipeline Automation (v5.3)

**Author:** Julio Cesar Nather Junior  
**Date:** September 2025

Bash script for PSMD (Peak Skeleton Mean Diffusivity) analysis with robust DTI data processing, including automatic fallback and batch processing.

## About PSMD

This script is an automation wrapper for [PSMD (Peak width of Skeletonized Mean Diffusivity)](https://github.com/miac-research/psmd), a robust, fully-automated and easy-to-implement marker for cerebral small vessel disease based on diffusion tensor imaging, white matter tract skeletonization (as implemented in FSL-TBSS) and histogram analysis.

**⚠️ Important Notice:** PSMD is NOT a medical device and **for academic research use only**. Do not use PSMD for diagnosis, prognosis, monitoring or any other clinical routine use. Any application in clinical routine is forbidden by law, e.g. by Medical Device Regulation article 5 in the EU.

**Original PSMD Implementation:** [https://github.com/miac-research/psmd](https://github.com/miac-research/psmd)

## Overview

The `psmd_diag_one.sh` is a PSMD diagnostic script that offers:

- **SINGLE mode**: Processes a single subject
- **BATCH mode**: Processes multiple subjects in parallel
- **Integrity verification**: Validation of dimensions, bvals, bvecs and b0s
- **Automatic sanitization**: Removes CRLF and transposes .bvec when necessary
- **Primary PSMD**: Execution with `-p` (preprocessing) or `-d` (direct) mode
- **Robust fallback**: Alternative processing without BET dependency
- **Parallel processing**: Support for multiple simultaneous jobs
- **CSV reports**: Automatic result consolidation

## Prerequisites

### Required Software
- **Docker**: For PSMD container execution
- **Bash 4.0+**: For advanced script features
- **curl or wget**: For automatic skeleton mask download

### Data Structure
Each subject must contain:
- **NIfTI file**: `.nii` or `.nii.gz` with DTI data
- **Bval file**: B-values
- **Bvec file**: Gradient directions (3xN)

### Naming Conventions
The script automatically detects files with the following patterns:
- `*DTI*.bval`, `*DTI*.bvec`, `*DTI*.nii*` (preferred)
- `*.bval`, `*.bvec`, `*.nii*` (generic)
- Support for files with `.nii.bval`/`.nii.bvec` suffix

## Usage

### Basic Syntax
```bash
PSMD_MODE=d|p ./psmd_diag_one.sh /path/to/data [mask_override]
```

### Execution Example
```bash
PSMD_MODE=p JOBS=8 OMP_THREADS=1 \
  PSMD_IMAGE=ghcr.io/miac-research/psmd:latest \
  ./psmd_diag_one.sh /mnt/e/datasets/maria_clara/PSMD
```

### Environment Variables

| Variable | Default | Description |
|---------|---------|-------------|
| `PSMD_MODE` | `p` | PSMD mode: `p` (preprocessing) or `d` (direct) |
| `PSMD_IMAGE` | `ghcr.io/miac-research/psmd:latest` | PSMD Docker image |
| `BET_F` | `0.30` | BET parameter (kept for compatibility) |
| `OMP_THREADS` | `1` | OpenMP threads for processing |
| `JOBS` | `1` | Number of parallel jobs (BATCH mode) |

## Operation Modes

### SINGLE Mode
Processes a single subject directory:
```bash
./psmd_diag_one.sh /path/to/Subject_01_RM1
```

### BATCH Mode
Processes all subjects in a directory:
```bash
./psmd_diag_one.sh /path/to/PSMD/
```

## Processing Flow

### 1. Integrity Verification
- **4D Dimension**: Validation of number of volumes
- **B-values**: Counting and validation of b-values
- **B-vectors**: Verification of 3xN matrix
- **B0 volumes**: Identification of b0 volumes (b < 50)

### 2. Data Sanitization
- **CRLF**: Automatic removal of Windows characters
- **Bvec transposition**: Automatic conversion from Nx3 to 3xN
- **Cleaning**: Creation of `.clean` files for processing

### 3. Primary PSMD
Executes PSMD with selected mode:
- **Mode `-p`**: Preprocessing + PSMD (requires `bc`)
- **Mode `-d`**: Direct PSMD (does not require `bc`)

### 4. Automatic Fallback
If primary mode fails, executes:
1. **B0 extraction**: `fslroi` to extract first b0 volume
2. **Adaptive mask**: Threshold based on percentiles (P2 + 0.20*(P98-P2))
3. **Morphological refinement**: Dilation/erosion for cleaning
4. **Tensor fitting**: `dtifit` to generate FA and MD
5. **Final PSMD**: Execution with `-f` (FA) and `-m` (MD)

## Output Structure

### Log Files
- `psmd_diag_YYYYMMDD_HHMMSS.log`: Complete diagnostic log
- `psmd_mode_p.log` / `psmd_mode_d.log`: Primary mode log
- `psmd_mode_fm.log`: Fallback log
- `psmd_precheck.txt`: Dependency verification

### Data Files (Fallback)
- `b0.nii.gz`: Extracted b0 volume
- `b0_brain_mask.nii.gz`: Brain mask
- `dti_FA.nii.gz`: Fractional Anisotropy
- `dti_MD.nii.gz`: Mean Diffusivity
- `dti_*.nii.gz`: Other DTI maps

### CSV Report (BATCH Mode)
File `psmd_results.csv` with columns:
- `subject`: Subject name
- `mode`: PSMD mode used
- `method`: Method (primary/fallback/fail)
- `psmd`: Calculated PSMD value
- `primary_log`: Primary log path
- `fallback_log`: Fallback log path
- `diag_log`: Diagnostic log path

## Error Handling

### Automatic Failure Detection
- **Missing dependencies**: Skips `-p` mode if `bc` not available
- **Processing failures**: Detects common errors in logs
- **Result validation**: Verifies presence of PSMD values

### Recovery Strategies
- **Automatic fallback**: Alternative execution without BET
- **Adaptive masks**: Automatic threshold adjustment
- **Robust validation**: Multiple integrity checks

## Performance Optimization

### Parallel Processing
```bash
JOBS=8  # Process up to 8 subjects simultaneously
```

### OpenMP Threading
```bash
OMP_THREADS=4  # 4 threads per job
```

### Recommended Configuration
```bash
# For systems with 8+ cores
PSMD_MODE=p JOBS=4 OMP_THREADS=2 \
  ./psmd_diag_one.sh /path/to/PSMD/
```

## Troubleshooting

### Common Issues

1. **"NIfTI not found"**
   - Check if files are in correct format
   - Confirm file naming

2. **"bc missing: skipping -p mode"**
   - Normal: script uses fallback automatically
   - Use `PSMD_MODE=d` to force direct mode

3. **"Operation not permitted"**
   - Fixed in v5.3: script uses `-w /tmp`

4. **Fallback failures**
   - Check if FSL is available in container
   - Confirm DTI data integrity

### Diagnostic Logs
All logs are saved with timestamp for easier debugging:
```bash
ls -la Subject_*/psmd_diag_*.log
```

## Usage Examples

### Individual Processing
```bash
# Single subject
./psmd_diag_one.sh /data/Subject_01_RM1

# With custom mask
./psmd_diag_one.sh /data/Subject_01_RM1 /path/to/custom_mask.nii.gz
```

### Batch Processing
```bash
# Parallel processing
PSMD_MODE=p JOBS=8 ./psmd_diag_one.sh /data/PSMD/

# Direct mode (without preprocessing)
PSMD_MODE=d JOBS=4 ./psmd_diag_one.sh /data/PSMD/
```

### Advanced Configuration
```bash
# Complete configuration
PSMD_MODE=p \
PSMD_IMAGE=ghcr.io/miac-research/psmd:latest \
OMP_THREADS=2 \
JOBS=6 \
./psmd_diag_one.sh /data/PSMD/
```

## Changelog

### v5.3
- **Fix**: Use of `-w /tmp` to avoid "Operation not permitted"
- **Improvement**: Robust NIfTI file detection
- **Optimization**: Simplified fallback logic
- **Compatibility**: Support for `.nii.bval`/`.nii.bvec` files

### v5.2
- **BET-free fallback**: Robust alternative processing
- **Sanitization**: Automatic CRLF cleaning and .bvec transposition
- **Parallelization**: Support for multiple simultaneous jobs

## Credits

- **Script Author:** Julio Cesar Nather Junior (September 2025)
- **Original PSMD:** [MIAC Research](https://github.com/miac-research/psmd) - Peak width of Skeletonized Mean Diffusivity
- **PSMD Development:** Institute for Stroke and Dementia Research (ISD), Munich, Germany
- **Ongoing Support:** Medical Image Analysis Center (MIAC AG), Basel, Switzerland

## Support

For problems or questions:
1. Check diagnostic logs
2. Confirm data structure
3. Test with individual subject first
4. Consult PSMD documentation: https://github.com/miac-research/psmd
