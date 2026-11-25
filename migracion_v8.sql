-- =====================================================================
-- CARTERA MULTIMONEDA — MIGRACIÓN v8: compra / venta de divisas (mostrador)
-- Ejecutar UNA vez después de migracion_v7.sql
-- =====================================================================

CREATE TABLE IF NOT EXISTS cambios (
    id               BIGSERIAL PRIMARY KEY,
    empresa_id       INT NOT NULL REFERENCES empresas(id),
    tipo             VARCHAR(6) NOT NULL CHECK (tipo IN ('COMPRA','VENTA')),
    moneda_codigo    VARCHAR(3) NOT NULL REFERENCES monedas(codigo) CHECK (moneda_codigo <> 'PYG'),
    cantidad         NUMERIC(18,4) NOT NULL CHECK (cantidad > 0),
    cotizacion       NUMERIC(18,6) NOT NULL CHECK (cotizacion > 0),
    total_gs         NUMERIC(18,0) NOT NULL CHECK (total_gs > 0),
    cliente_nombre   TEXT,
    cliente_doc      TEXT,
    metodo_pago      VARCHAR(20) NOT NULL DEFAULT 'EFECTIVO' CHECK (metodo_pago IN ('EFECTIVO','TRANSFERENCIA','CHEQUE')),
    concepto         TEXT,
    usuario_registro TEXT NOT NULL,
    fecha            TIMESTAMPTZ NOT NULL DEFAULT now(),
    anulada          BOOLEAN NOT NULL DEFAULT FALSE,
    anulada_por      TEXT,
    anulada_fecha    TIMESTAMPTZ,
    motivo_anulacion TEXT
);
CREATE INDEX IF NOT EXISTS ix_cambios_empresa_fecha ON cambios (empresa_id, fecha);

-- Inmutable: solo se marca anulada desde la función, o se borra al reiniciar la empresa
CREATE OR REPLACE FUNCTION fn_proteger_cambios() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF coalesce(current_setting('app.reset_empresa', true), '') = OLD.empresa_id::TEXT THEN RETURN OLD; END IF;
        RAISE EXCEPTION 'Las operaciones de cambio no se borran: anúlelas';
    END IF;
    IF coalesce(current_setting('app.via_funcion', true), 'off') <> 'on'
       OR (NEW.tipo, NEW.moneda_codigo, NEW.cantidad, NEW.cotizacion, NEW.total_gs, NEW.fecha, NEW.empresa_id)
          IS DISTINCT FROM (OLD.tipo, OLD.moneda_codigo, OLD.cantidad, OLD.cotizacion, OLD.total_gs, OLD.fecha, OLD.empresa_id) THEN
        RAISE EXCEPTION 'Las operaciones de cambio no se modifican: anúlelas';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_cambios_proteger ON cambios;
CREATE TRIGGER trg_cambios_proteger BEFORE UPDATE OR DELETE ON cambios
FOR EACH ROW EXECUTE FUNCTION fn_proteger_cambios();

-- Registrar compra o venta
CREATE OR REPLACE FUNCTION api_registrar_cambio(
    p_tipo TEXT, p_moneda TEXT, p_cantidad NUMERIC, p_cotizacion NUMERIC,
    p_cliente_nombre TEXT DEFAULT NULL, p_cliente_doc TEXT DEFAULT NULL,
    p_metodo TEXT DEFAULT 'EFECTIVO', p_concepto TEXT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; dec INT; q NUMERIC; tot NUMERIC; v_id BIGINT;
BEGIN
    v := fn_perfil_actual();
    IF upper(p_tipo) NOT IN ('COMPRA','VENTA') THEN RAISE EXCEPTION 'Tipo inválido'; END IF;
    SELECT decimales INTO dec FROM monedas WHERE codigo = upper(p_moneda) AND codigo <> 'PYG';
    IF NOT FOUND THEN RAISE EXCEPTION 'Moneda inválida'; END IF;
    q := round(p_cantidad, dec);
    IF q IS NULL OR q <= 0 THEN RAISE EXCEPTION 'Cantidad inválida'; END IF;
    IF p_cotizacion IS NULL OR p_cotizacion <= 0 THEN RAISE EXCEPTION 'Cotización inválida'; END IF;
    tot := round(q * p_cotizacion, 0);
    INSERT INTO cambios (empresa_id, tipo, moneda_codigo, cantidad, cotizacion, total_gs, cliente_nombre, cliente_doc, metodo_pago, concepto, usuario_registro)
    VALUES (v.empresa_id, upper(p_tipo), upper(p_moneda), q, p_cotizacion, tot,
            nullif(trim(p_cliente_nombre), ''), nullif(trim(p_cliente_doc), ''), upper(coalesce(p_metodo, 'EFECTIVO')),
            nullif(trim(p_concepto), ''), v.email)
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- Anular (supervisor o administrador)
CREATE OR REPLACE FUNCTION api_anular_cambio(p_id BIGINT, p_motivo TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual(ARRAY['SUPERVISOR','ADMIN']);
    IF coalesce(trim(p_motivo), '') = '' THEN RAISE EXCEPTION 'Indique el motivo'; END IF;
    IF NOT EXISTS (SELECT 1 FROM cambios WHERE id = p_id AND empresa_id = v.empresa_id AND NOT anulada) THEN
        RAISE EXCEPTION 'Operación inexistente o ya anulada';
    END IF;
    PERFORM set_config('app.via_funcion', 'on', true);
    UPDATE cambios SET anulada = TRUE, anulada_por = v.email, anulada_fecha = now(), motivo_anulacion = trim(p_motivo) WHERE id = p_id;
    PERFORM set_config('app.via_funcion', 'off', true);
END $$;

-- Reinicio de empresa también borra compras/ventas
CREATE OR REPLACE FUNCTION api_reiniciar_empresa(p_confirmacion TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; n_cli INT; n_op INT; n_mov INT; n_cot INT; n_cam INT;
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    IF upper(trim(coalesce(p_confirmacion, ''))) <> 'REINICIAR' THEN
        RAISE EXCEPTION 'Escriba REINICIAR para confirmar';
    END IF;
    PERFORM set_config('app.reset_empresa', v.empresa_id::TEXT, true);
    DELETE FROM movimientos_cartera WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_mov = ROW_COUNT;
    DELETE FROM operaciones         WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_op  = ROW_COUNT;
    DELETE FROM cartera_cliente     WHERE empresa_id = v.empresa_id;
    DELETE FROM clientes            WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_cli = ROW_COUNT;
    DELETE FROM cotizaciones        WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_cot = ROW_COUNT;
    DELETE FROM cambios             WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_cam = ROW_COUNT;
    PERFORM set_config('app.reset_empresa', '', true);
    RETURN jsonb_build_object('clientes', n_cli, 'operaciones', n_op, 'movimientos', n_mov, 'cotizaciones', n_cot, 'cambios', n_cam);
END $$;

-- Seguridad
ALTER TABLE cambios ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lectura_empresa ON cambios;
CREATE POLICY lectura_empresa ON cambios FOR SELECT TO authenticated USING (empresa_id = fn_empresa_actual() AND fn_empresa_vigente(empresa_id));
REVOKE ALL ON cambios FROM anon, authenticated;
REVOKE ALL ON SEQUENCE cambios_id_seq FROM anon, authenticated;
GRANT SELECT ON cambios TO authenticated;
REVOKE EXECUTE ON FUNCTION api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT), api_anular_cambio(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT), api_anular_cambio(BIGINT, TEXT), api_reiniciar_empresa(TEXT) TO authenticated;
