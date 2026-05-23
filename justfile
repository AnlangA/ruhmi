set windows-shell := ["pwsh.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]

ruhmi_repo := "https://github.com/renesas/ruhmi-framework-mcu.git"
ruhmi_dir := "ruhmi-framework-mcu"
model_url := "https://huggingface.co/jack-perlo/Lenet5-Mnist/resolve/main/lenet5_int8_mnist.tflite"
model_file := "models/lenet5_int8_mnist.tflite"
out_dir := "deploy_output"
compiled_dir := "lenet5_int8_mnist_NPU"

default:
    @just --list

all: install-python310 download-model download-ruhmi setup convert metrics

install-python310:
    $ErrorActionPreference = 'Stop'; $root = (Get-Location).Path; $tools = Join-Path $root 'tools'; $target = Join-Path $tools 'python310'; $python = Join-Path $target 'python.exe'; if (Test-Path $python) { try { & $python --version; exit 0 } catch { Write-Host 'Existing Python install is broken, removing...'; Remove-Item -Recurse -Force $target -ErrorAction SilentlyContinue } }; if (Get-Command py -ErrorAction SilentlyContinue) { py -3.10 --version; if ($LASTEXITCODE -eq 0) { Write-Host 'Python 3.10 is already available through py -3.10'; exit 0 } }; New-Item -ItemType Directory -Force -Path $tools | Out-Null; if (Test-Path $target) { Remove-Item -Recurse -Force $target -ErrorAction SilentlyContinue }; $zip = Join-Path $tools 'python-3.10.11-embed-amd64.zip'; $zipOk = $false; if (Test-Path $zip) { try { $t = [System.IO.Compression.ZipFile]::OpenRead($zip); $t.Dispose(); $zipOk = $true } catch { Write-Host 'Corrupted zip, re-downloading...'; Remove-Item $zip -Force } }; if (-not $zipOk) { Write-Host 'Downloading Python 3.10 embeddable...'; curl.exe -L -f -o $zip 'https://www.python.org/ftp/python/3.10.11/python-3.10.11-embed-amd64.zip'; if ($LASTEXITCODE -ne 0) { throw 'Failed to download Python 3.10.11 embeddable zip.' } }; Write-Host 'Extracting Python 3.10...'; [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $target); $pth = Join-Path $target 'python310._pth'; if (Test-Path $pth) { $c = Get-Content $pth; if ($c -contains '#import site') { Write-Host 'Enabling site-packages...'; $c = $c -replace '^#import site', 'import site'; $c | Set-Content $pth } }; $getpip = Join-Path $tools 'get-pip.py'; if (!(Test-Path $getpip)) { Write-Host 'Downloading get-pip.py...'; curl.exe -L -f -o $getpip 'https://bootstrap.pypa.io/get-pip.py'; if ($LASTEXITCODE -ne 0) { throw 'Failed to download get-pip.py.' } }; Write-Host 'Installing pip...'; & $python $getpip --no-warn-script-location; if ($LASTEXITCODE -ne 0) { throw 'Failed to install pip.' }; Write-Host 'Installing virtualenv...'; & $python -m pip install virtualenv --no-warn-script-location; if ($LASTEXITCODE -ne 0) { throw 'Failed to install virtualenv.' }; Write-Host 'Python 3.10 installed successfully'; & $python --version

check-tools:
    $ErrorActionPreference = 'Stop'; foreach ($cmd in @('git', 'curl.exe')) { if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "Missing required command: $cmd" } }; $local = Join-Path (Get-Location).Path 'tools\python310\python.exe'; if (Test-Path $local) { try { & $local --version; exit 0 } catch { Write-Host 'Local Python install appears broken, will need reinstall.' } }; if (-not (Get-Command py -ErrorAction SilentlyContinue)) { throw 'Python 3.10 is required. Run: just install-python310' }; py -3.10 --version; if ($LASTEXITCODE -ne 0) { throw 'Python 3.10 is required. Run: just install-python310' }

download-model: check-tools
    $ErrorActionPreference = 'Stop'; $model = '{{model_file}}'; New-Item -ItemType Directory -Force -Path (Split-Path $model) | Out-Null; if (!(Test-Path $model)) { curl.exe -L -f -o $model '{{model_url}}'; if ($LASTEXITCODE -ne 0) { throw 'Failed to download MNIST INT8 TFLite model.' } } else { Write-Host "Model already exists: $model" }

download-ruhmi: check-tools
    $ErrorActionPreference = 'Stop'; if (!(Test-Path '{{ruhmi_dir}}')) { git clone '{{ruhmi_repo}}' '{{ruhmi_dir}}'; if ($LASTEXITCODE -ne 0) { throw 'Failed to clone RUHMI framework.' } } else { Write-Host "RUHMI already exists: {{ruhmi_dir}}" }

setup: download-ruhmi
    $ErrorActionPreference = 'Stop'; $root = (Get-Location).Path; $repo = Join-Path $root '{{ruhmi_dir}}'; $venv = Join-Path $repo '.venv'; $python = Join-Path $venv 'Scripts\python.exe'; $local = Join-Path $root 'tools\python310\python.exe'; if (!(Test-Path $python)) { if (Test-Path $local) { & $local -m virtualenv $venv } else { py -3.10 -m virtualenv $venv }; if ($LASTEXITCODE -ne 0) { throw 'Failed to create Python 3.10 virtual environment.' } }; & $python -m pip install --upgrade pip; if ($LASTEXITCODE -ne 0) { throw 'Failed to upgrade pip.' }; & $python -m pip install decorator typing_extensions psutil attrs pybind11 cmake junitparser onnx==1.17.0 tflite==2.18.0; if ($LASTEXITCODE -ne 0) { throw 'Failed to install Python dependencies.' }; $wheel = Get-ChildItem (Join-Path $repo 'install') -Filter 'mera-*-cp310-cp310-win_amd64.whl' | Select-Object -First 1; if (!$wheel) { throw 'RUHMI MERA Windows cp310 wheel was not found under ruhmi-framework-mcu\install.' }; & $python -m pip install $wheel.FullName; if ($LASTEXITCODE -ne 0) { throw 'Failed to install RUHMI MERA wheel.' }

convert: setup download-model
    $ErrorActionPreference = 'Stop'; $root = (Get-Location).Path; $repo = Join-Path $root '{{ruhmi_dir}}'; $venvBin = Join-Path $repo '.venv\Scripts'; $python = Join-Path $venvBin 'python.exe'; $model = Join-Path $root '{{model_file}}'; $out = Join-Path $root '{{out_dir}}'; if (!(Test-Path $model)) { throw 'Model file not found. Run: just download-model' }; New-Item -ItemType Directory -Force -Path $out | Out-Null; $env:PATH = "$venvBin;$env:PATH"; Push-Location $repo; try { & $python scripts\mcu_compile.py $model $out --npu; if ($LASTEXITCODE -ne 0) { throw 'RUHMI NPU compilation failed.' } } finally { Pop-Location }; Write-Host "Expected RA8P1 NPU output: $(Join-Path $out '{{compiled_dir}}')"

metrics: convert
    $ErrorActionPreference = 'Stop'; $root = (Get-Location).Path; $repo = Join-Path $root '{{ruhmi_dir}}'; $python = Join-Path $repo '.venv\Scripts\python.exe'; $out = Join-Path $root '{{out_dir}}\{{compiled_dir}}'; if (!(Test-Path $out)) { $candidate = Get-ChildItem (Join-Path $root '{{out_dir}}') -Directory -Filter '*_NPU' | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($candidate) { $out = $candidate.FullName } }; if (!(Test-Path $out)) { throw 'Compiled NPU output directory was not found.' }; Push-Location $repo; try { & $python scripts\utils\check_model_metrics.py $out; if ($LASTEXITCODE -ne 0) { throw 'RUHMI metrics check failed.' } } finally { Pop-Location }
