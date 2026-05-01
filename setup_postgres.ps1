#Requires -Version 5.1
<#
.SYNOPSIS
    Setup completo do PostgreSQL para o projeto BBSIA.

.DESCRIPTION
    - Verifica pre-requisitos (Docker, Docker Compose)
    - Cria .env com senha segura se nao existir
    - Sobe o container PostgreSQL via Docker Compose
    - Aguarda o healthcheck ficar healthy
    - Valida o schema aplicado
    - Exibe string de conexao pronta para o .env do projeto

.EXAMPLE
    .\setup_postgres.ps1

.EXAMPLE
    .\setup_postgres.ps1 -Senha "minha_senha_forte" -SemAdminer
#>

[CmdletBinding()]
param(
    [string] $Senha       = "",          # Se vazio, gera automaticamente
    [switch] $SemAdminer,                # Nao sobe o Adminer
    [switch] $RecriarBanco,              # Derruba e recria tudo (APAGA DADOS)
    [int]    $TimeoutSeg  = 120          # Tempo maximo para o healthcheck
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ─── Cores ────────────────────────────────────────────────────────────────────
function Write-Ok    { param($msg) Write-Host "  [OK] $msg"    -ForegroundColor Green  }
function Write-Info  { param($msg) Write-Host "  [..] $msg"    -ForegroundColor Cyan   }
function Write-Warn  { param($msg) Write-Host "  [!] $msg"     -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host "  [ERRO] $msg"  -ForegroundColor Red; exit 1 }

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Blue
    Write-Host "  ║   BBSIA — Setup PostgreSQL (Docker)      ║" -ForegroundColor Blue
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Blue
    Write-Host ""
}

# ─── Utilitarios ──────────────────────────────────────────────────────────────
function Test-Comando {
    param([string]$Cmd)
    return [bool](Get-Command $Cmd -ErrorAction SilentlyContinue)
}

function New-SenhaAleatoria {
    $chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789!@#%^&*"
    -join (1..24 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

function Get-ScriptDir {
    Split-Path -Parent $MyInvocation.ScriptName
}

# ─── Pre-requisitos ────────────────────────────────────────────────────────────
function Test-PreRequisitos {
    Write-Info "Verificando pre-requisitos..."

    if (-not (Test-Comando "docker")) {
        Write-Fail "Docker nao encontrado. Instale o Docker Desktop: https://www.docker.com/products/docker-desktop"
    }
    Write-Ok "Docker encontrado: $(docker --version)"

    # Verifica se o Docker esta rodando
    try {
        docker info 2>&1 | Out-Null
    } catch {
        Write-Fail "Docker nao esta rodando. Inicie o Docker Desktop e tente novamente."
    }
    Write-Ok "Docker Engine esta ativo."

    # Docker Compose v2 (embutido) ou v1 (plugin separado)
    $composeOk = $false
    try { docker compose version 2>&1 | Out-Null; $composeOk = $true } catch {}
    if (-not $composeOk) {
        try { docker-compose version 2>&1 | Out-Null; $composeOk = $true } catch {}
    }
    if (-not $composeOk) {
        Write-Fail "Docker Compose nao encontrado. Atualize o Docker Desktop para a versao mais recente."
    }
    Write-Ok "Docker Compose encontrado."
}

# ─── Arquivos necessarios ──────────────────────────────────────────────────────
function Test-Arquivos {
    param([string]$Dir)

    $sql     = Join-Path $Dir "bbsia_metadata.sql"
    $compose = Join-Path $Dir "docker-compose.postgres.yml"

    if (-not (Test-Path $sql)) {
        Write-Fail "Arquivo nao encontrado: $sql`nCopie bbsia_metadata.sql para a pasta do projeto."
    }
    if (-not (Test-Path $compose)) {
        Write-Fail "Arquivo nao encontrado: $compose`nCopie docker-compose.postgres.yml para a pasta do projeto."
    }

    Write-Ok "Arquivos de configuracao encontrados."
}

# ─── .env ─────────────────────────────────────────────────────────────────────
function Set-EnvFile {
    param([string]$Dir, [string]$SenhaParam)

    $envFile = Join-Path $Dir ".env"

    # Le senha existente se o .env ja tiver a variavel
    $senhaExistente = ""
    if (Test-Path $envFile) {
        $linhas = Get-Content $envFile
        foreach ($linha in $linhas) {
            if ($linha -match "^POSTGRES_PASSWORD=(.+)$") {
                $senhaExistente = $Matches[1]
                break
            }
        }
    }

    if ($senhaExistente) {
        Write-Ok ".env ja possui POSTGRES_PASSWORD definida. Mantendo."
        return $senhaExistente
    }

    $senha = if ($SenhaParam) { $SenhaParam } else { New-SenhaAleatoria }

    # Adiciona ou cria o .env
    if (Test-Path $envFile) {
        Add-Content $envFile "`nPOSTGRES_PASSWORD=$senha"
        Write-Ok "POSTGRES_PASSWORD adicionada ao .env existente."
    } else {
        Set-Content $envFile "POSTGRES_PASSWORD=$senha"
        Write-Ok ".env criado com senha gerada automaticamente."
    }

    Write-Warn "Guarde essa senha em local seguro: $senha"
    return $senha
}

# ─── Recriar banco (opcional) ──────────────────────────────────────────────────
function Remove-BancoExistente {
    param([string]$Dir)

    Write-Warn "Flag -RecriarBanco detectada. TODOS OS DADOS SERAO APAGADOS."
    $confirmacao = Read-Host "  Digite CONFIRMAR para continuar (qualquer outra coisa cancela)"
    if ($confirmacao -ne "CONFIRMAR") {
        Write-Info "Operacao cancelada pelo usuario."
        exit 0
    }

    Write-Info "Derrubando containers e volumes existentes..."
    Push-Location $Dir
    try {
        docker compose -f docker-compose.postgres.yml down -v 2>&1 | Out-Null
        Write-Ok "Containers e volumes removidos."
    } finally {
        Pop-Location
    }
}

# ─── Subir containers ──────────────────────────────────────────────────────────
function Start-Containers {
    param([string]$Dir, [bool]$ComAdminer)

    Write-Info "Iniciando containers..."
    Push-Location $Dir
    try {
        if ($ComAdminer) {
            docker compose -f docker-compose.postgres.yml --profile tools up -d 2>&1
        } else {
            docker compose -f docker-compose.postgres.yml up -d 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "docker compose up falhou. Verifique os logs acima."
        }
    } finally {
        Pop-Location
    }
    Write-Ok "Containers iniciados."
}

# ─── Aguardar healthcheck ──────────────────────────────────────────────────────
function Wait-Healthy {
    param([int]$TimeoutSeg)

    Write-Info "Aguardando PostgreSQL ficar saudavel (timeout: ${TimeoutSeg}s)..."
    $inicio   = Get-Date
    $saudavel = $false

    while ((New-TimeSpan -Start $inicio -End (Get-Date)).TotalSeconds -lt $TimeoutSeg) {
        $saida = docker inspect --format "{{.State.Health.Status}}" bbsia_postgres 2>&1
        if ($saida -eq "healthy") {
            $saudavel = $true
            break
        }
        Write-Host "    status: $saida — aguardando..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 4
    }

    if (-not $saudavel) {
        Write-Fail "Timeout: PostgreSQL nao ficou saudavel em ${TimeoutSeg}s.`nVeja os logs: docker logs bbsia_postgres"
    }
    Write-Ok "PostgreSQL esta saudavel."
}

# ─── Validar schema ────────────────────────────────────────────────────────────
function Test-Schema {
    $tabelasEsperadas = @(
        "auditoria", "conversas", "documentos",
        "mensagens", "reprocessamentos", "uploads"
    )

    Write-Info "Validando schema bbsia..."
    $query = "SELECT tablename FROM pg_tables WHERE schemaname = 'bbsia' ORDER BY tablename;"
    $saida = docker exec bbsia_postgres psql -U bbsia_user -d bbsia -t -c $query 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Nao foi possivel consultar o schema: $saida"
    }

    $tabelasEncontradas = ($saida -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })

    $faltando = @()
    foreach ($tabela in $tabelasEsperadas) {
        if ($tabela -notin $tabelasEncontradas) {
            $faltando += $tabela
        }
    }

    if ($faltando.Count -gt 0) {
        Write-Fail "Tabelas ausentes no schema: $($faltando -join ', ')"
    }

    Write-Ok "Schema validado: $($tabelasEsperadas.Count) tabelas encontradas."
}

# ─── Exibir resumo ─────────────────────────────────────────────────────────────
function Show-Resumo {
    param([string]$Senha)

    $connectionString = "postgresql://bbsia_user:$Senha@localhost:5432/bbsia"

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║                  SETUP CONCLUIDO COM SUCESSO                ║" -ForegroundColor Green
    Write-Host "  ╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Green
    Write-Host "  ║  Host    : localhost:5432                                    ║" -ForegroundColor Green
    Write-Host "  ║  Banco   : bbsia                                             ║" -ForegroundColor Green
    Write-Host "  ║  Usuario : bbsia_user                                        ║" -ForegroundColor Green
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Adicione ao .env do projeto BBSIA:" -ForegroundColor Yellow
    Write-Host "  DATABASE_URL=$connectionString" -ForegroundColor White
    Write-Host ""
    Write-Host "  Comandos uteis:" -ForegroundColor Cyan
    Write-Host "    Parar banco   : docker compose -f docker-compose.postgres.yml stop"
    Write-Host "    Ver logs      : docker compose -f docker-compose.postgres.yml logs -f postgres"
    Write-Host "    Abrir psql    : docker exec -it bbsia_postgres psql -U bbsia_user -d bbsia"
    Write-Host "    Backup        : docker exec bbsia_postgres pg_dump -U bbsia_user bbsia > backup.sql"
    Write-Host ""

    Write-Host "  Views disponiveis no banco:" -ForegroundColor Cyan
    Write-Host "    SELECT * FROM bbsia.v_biblioteca_resumo;"
    Write-Host "    SELECT * FROM bbsia.v_uploads_pendentes;"
    Write-Host "    SELECT * FROM bbsia.v_erros_recentes;"
    Write-Host ""
}

# ─── MAIN ──────────────────────────────────────────────────────────────────────
Write-Banner

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

Test-PreRequisitos
Test-Arquivos -Dir $dir

if ($RecriarBanco) {
    Remove-BancoExistente -Dir $dir
}

$senhaFinal = Set-EnvFile -Dir $dir -SenhaParam $Senha
Start-Containers -Dir $dir -ComAdminer (-not $SemAdminer)
Wait-Healthy -TimeoutSeg $TimeoutSeg
Test-Schema
Show-Resumo -Senha $senhaFinal
