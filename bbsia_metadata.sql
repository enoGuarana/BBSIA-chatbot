-- =============================================================================
-- BBSIA - Schema de Metadados e Auditoria
-- PostgreSQL 16+
-- Escopo: metadados de documentos, uploads, auditoria e historico de conversa
-- Vetores (chunks/embeddings) permanecem no Qdrant local nesta fase
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Extensoes
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- busca por trigrama em titulos

-- -----------------------------------------------------------------------------
-- Schema dedicado
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS bbsia;
SET search_path TO bbsia, public;

-- =============================================================================
-- 1. DOCUMENTOS (substitui data/biblioteca.json)
-- =============================================================================
CREATE TABLE IF NOT EXISTS bbsia.documentos (
    id                   TEXT        PRIMARY KEY,
    titulo               TEXT        NOT NULL DEFAULT '',
    autores              TEXT[]      NOT NULL DEFAULT '{}',
    ano                  SMALLINT    CHECK (ano IS NULL OR (ano >= 1900 AND ano <= 2100)),
    instituicao          TEXT        NOT NULL DEFAULT '',
    tipo_documento       TEXT        NOT NULL DEFAULT 'outro'
                             CHECK (tipo_documento IN (
                                 'artigo_cientifico', 'relatorio_tecnico',
                                 'manual', 'apresentacao', 'outro'
                             )),
    resumo               TEXT        NOT NULL DEFAULT '',
    palavras_chave       TEXT[]      NOT NULL DEFAULT '{}',
    area_tematica        TEXT        NOT NULL DEFAULT 'geral'
                             CHECK (area_tematica IN (
                                 'ia', 'saude', 'infraestrutura',
                                 'juridico', 'tecnologia', 'geral'
                             )),
    assuntos             TEXT[]      NOT NULL DEFAULT '{}',
    metodologia          TEXT        NOT NULL DEFAULT 'outro',
    secoes_detectadas    TEXT[]      NOT NULL DEFAULT '{}',
    paginas_total        SMALLINT    NOT NULL DEFAULT 0 CHECK (paginas_total >= 0),
    documento_original   TEXT        NOT NULL DEFAULT '',
    qualidade_extracao   TEXT        NOT NULL DEFAULT 'media'
                             CHECK (qualidade_extracao IN ('alta', 'media', 'baixa')),
    data_ingestao        TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_em        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_documentos_area
    ON bbsia.documentos (area_tematica);

CREATE INDEX IF NOT EXISTS idx_documentos_ano
    ON bbsia.documentos (ano);

CREATE INDEX IF NOT EXISTS idx_documentos_tipo
    ON bbsia.documentos (tipo_documento);

CREATE INDEX IF NOT EXISTS idx_documentos_titulo_trgm
    ON bbsia.documentos USING gin (titulo gin_trgm_ops);

COMMENT ON TABLE bbsia.documentos IS
    'Catalogo de documentos indexados. Equivale ao data/biblioteca.json.';

-- =============================================================================
-- 2. UPLOADS (substitui uploads/metadata_uploads.json)
-- =============================================================================
CREATE TABLE IF NOT EXISTS bbsia.uploads (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    chave_normalizda            TEXT        NOT NULL UNIQUE,   -- ex: uploads/arquivo.pdf
    original_filename           TEXT        NOT NULL,
    stored_filename             TEXT        NOT NULL,
    area                        TEXT        NOT NULL DEFAULT 'geral',
    assuntos                    TEXT[]      NOT NULL DEFAULT '{}',
    status                      TEXT        NOT NULL DEFAULT 'quarantined_pending_review'
                                    CHECK (status IN (
                                        'quarantined_pending_review',
                                        'quarantined_prompt_review',
                                        'approved_pending_index',
                                        'indexed',
                                        'rejected'
                                    )),
    sha256                      CHAR(64),
    size_bytes                  INTEGER     CHECK (size_bytes IS NULL OR size_bytes > 0),
    page_count                  SMALLINT    CHECK (page_count IS NULL OR page_count >= 0),
    extracted_chars             INTEGER     CHECK (extracted_chars IS NULL OR extracted_chars >= 0),
    prompt_injection_findings   TEXT[]      NOT NULL DEFAULT '{}',
    quarantine_path             TEXT,
    approved_path               TEXT,
    uploaded_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_at                 TIMESTAMPTZ,
    indexed_at                  TIMESTAMPTZ,
    atualizado_em               TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_uploads_status
    ON bbsia.uploads (status);

CREATE INDEX IF NOT EXISTS idx_uploads_uploaded_at
    ON bbsia.uploads (uploaded_at DESC);

COMMENT ON TABLE bbsia.uploads IS
    'Rastreamento do ciclo de vida de PDFs enviados: quarentena → aprovacao → indexacao.';

COMMENT ON COLUMN bbsia.uploads.chave_normalizda IS
    'Chave normalizada no formato uploads/<arquivo.pdf>, usada como lookup primario.';

-- =============================================================================
-- 3. EVENTOS DE AUDITORIA (substitui data/audit.log)
-- =============================================================================
CREATE TABLE IF NOT EXISTS bbsia.auditoria (
    id          BIGSERIAL   PRIMARY KEY,
    ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    evento      TEXT        NOT NULL,
    client_ip   TEXT,
    metodo_http TEXT,
    path_http   TEXT,
    detalhes    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    run_id      INTEGER,        -- liga ao reprocessamento quando aplicavel
    nivel       TEXT        NOT NULL DEFAULT 'INFO'
                    CHECK (nivel IN ('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'))
);

-- Particionar por mes seria ideal em producao; por ora, indices cobrem o piloto
CREATE INDEX IF NOT EXISTS idx_auditoria_ts
    ON bbsia.auditoria (ts DESC);

CREATE INDEX IF NOT EXISTS idx_auditoria_evento
    ON bbsia.auditoria (evento);

CREATE INDEX IF NOT EXISTS idx_auditoria_client_ip
    ON bbsia.auditoria (client_ip);

CREATE INDEX IF NOT EXISTS idx_auditoria_nivel
    ON bbsia.auditoria (nivel)
    WHERE nivel IN ('WARNING', 'ERROR', 'CRITICAL');

CREATE INDEX IF NOT EXISTS idx_auditoria_detalhes
    ON bbsia.auditoria USING gin (detalhes);

COMMENT ON TABLE bbsia.auditoria IS
    'Log estruturado de eventos da API. Substitui data/audit.log (NDJSON).';

-- =============================================================================
-- 4. REPROCESSAMENTOS (complementa ReprocessWorker)
-- =============================================================================
CREATE TABLE IF NOT EXISTS bbsia.reprocessamentos (
    run_id          SERIAL      PRIMARY KEY,
    status          TEXT        NOT NULL DEFAULT 'enfileirado'
                        CHECK (status IN (
                            'enfileirado', 'rodando',
                            'concluido', 'falhou'
                        )),
    motivo          TEXT        NOT NULL DEFAULT 'manual',
    etapa_atual     TEXT,
    ultima_etapa    TEXT,
    erro            TEXT,
    iniciado_em     TIMESTAMPTZ,
    concluido_em    TIMESTAMPTZ,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT now(),
    metricas        JSONB       NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_reprocessamentos_status
    ON bbsia.reprocessamentos (status);

CREATE INDEX IF NOT EXISTS idx_reprocessamentos_criado_em
    ON bbsia.reprocessamentos (criado_em DESC);

COMMENT ON TABLE bbsia.reprocessamentos IS
    'Historico de execucoes do pipeline de reprocessamento (extracao → chunking → embedding → reload).';

-- =============================================================================
-- 5. HISTORICO DE CONVERSAS (substitui _CONVERSATION_HISTORY em memoria)
-- =============================================================================
CREATE TABLE IF NOT EXISTS bbsia.conversas (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    criada_em       TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizada_em   TIMESTAMPTZ NOT NULL DEFAULT now(),
    area_filtro     TEXT,
    modelo_usado    TEXT,
    total_mensagens SMALLINT    NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS bbsia.mensagens (
    id              BIGSERIAL   PRIMARY KEY,
    conversa_id     UUID        NOT NULL REFERENCES bbsia.conversas (id) ON DELETE CASCADE,
    role            TEXT        NOT NULL CHECK (role IN ('user', 'assistant')),
    conteudo        TEXT        NOT NULL,
    fontes          TEXT[]      NOT NULL DEFAULT '{}',
    criada_em       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mensagens_conversa
    ON bbsia.mensagens (conversa_id, criada_em ASC);

COMMENT ON TABLE bbsia.conversas IS
    'Sessoes de conversa. Substitui o dict _CONVERSATION_HISTORY mantido em memoria.';

COMMENT ON TABLE bbsia.mensagens IS
    'Mensagens individuais de cada sessao, em ordem cronologica.';

-- =============================================================================
-- 6. TRIGGERS: atualizado_em automatico
-- =============================================================================
CREATE OR REPLACE FUNCTION bbsia.set_atualizado_em()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.atualizado_em = now();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_documentos_atualizado_em
    BEFORE UPDATE ON bbsia.documentos
    FOR EACH ROW EXECUTE FUNCTION bbsia.set_atualizado_em();

CREATE OR REPLACE TRIGGER trg_uploads_atualizado_em
    BEFORE UPDATE ON bbsia.uploads
    FOR EACH ROW EXECUTE FUNCTION bbsia.set_atualizado_em();

CREATE OR REPLACE TRIGGER trg_conversas_atualizado_em
    BEFORE UPDATE ON bbsia.conversas
    FOR EACH ROW EXECUTE FUNCTION bbsia.set_atualizado_em();

-- =============================================================================
-- 7. VIEWS UTEIS
-- =============================================================================

-- Resumo da biblioteca por area
CREATE OR REPLACE VIEW bbsia.v_biblioteca_resumo AS
SELECT
    area_tematica,
    tipo_documento,
    COUNT(*)                            AS total_documentos,
    AVG(paginas_total)::NUMERIC(6,1)    AS media_paginas,
    COUNT(*) FILTER (WHERE qualidade_extracao = 'alta')  AS qualidade_alta,
    COUNT(*) FILTER (WHERE qualidade_extracao = 'media') AS qualidade_media,
    COUNT(*) FILTER (WHERE qualidade_extracao = 'baixa') AS qualidade_baixa
FROM bbsia.documentos
GROUP BY area_tematica, tipo_documento
ORDER BY area_tematica, total_documentos DESC;

-- Uploads pendentes de aprovacao
CREATE OR REPLACE VIEW bbsia.v_uploads_pendentes AS
SELECT
    id,
    chave_normalizda,
    original_filename,
    area,
    assuntos,
    status,
    page_count,
    size_bytes,
    array_length(prompt_injection_findings, 1) AS alertas_injecao,
    uploaded_at
FROM bbsia.uploads
WHERE status IN ('quarantined_pending_review', 'quarantined_prompt_review')
ORDER BY uploaded_at DESC;

-- Ultimos erros de auditoria
CREATE OR REPLACE VIEW bbsia.v_erros_recentes AS
SELECT
    ts,
    evento,
    client_ip,
    path_http,
    detalhes->>'error'  AS mensagem_erro,
    detalhes->>'stage'  AS etapa
FROM bbsia.auditoria
WHERE nivel IN ('ERROR', 'CRITICAL')
ORDER BY ts DESC
LIMIT 200;

-- =============================================================================
-- 8. DADOS INICIAIS DE REFERENCIA
-- =============================================================================
INSERT INTO bbsia.reprocessamentos (status, motivo, criado_em)
VALUES ('concluido', 'schema_inicial', now())
ON CONFLICT DO NOTHING;

-- =============================================================================
-- FIM DO SCHEMA
-- =============================================================================
