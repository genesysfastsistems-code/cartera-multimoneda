-- =====================================================================
-- CARTERA MULTIMONEDA — MIGRACIÓN v9: compra/venta vinculada a cliente registrado
-- Ejecutar UNA vez después de migracion_v8.sql
-- =====================================================================

ALTER TABLE cambios ADD COLUMN IF NOT EXISTS cliente_id INT REFERENCES clientes(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS ix_cambios_cliente ON cambios (cliente_id);

-- El reinicio borra clientes: primero se borran los cambios (ya incluido en api_reiniciar_empresa v8,
-- pero el orden debe ser cambios -> clientes)
CREATE OR REPLACE FUNCTION api_reiniciar_empresa(p_confirmacion TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; n_cli INT; n_op INT; n_mov INT; n_cot INT; n_cam INT;
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    IF upper(trim(coalesce(p_confirmacion, ''))) <> 'REINICIAR' THEN
        RAISE EXCEPTION 'Escriba REINICIAR para confirmar';
    END IF;
    PERFORM set_config('app.reset_empresa', v.empresa_id::TEXT, true);
    DELETE FROM cambios             WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_cam = ROW_COUNT;
    DELETE FROM movimientos_cartera WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_mov = ROW_COUNT;
    DELETE FROM operaciones         WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_op  = ROW_COUNT;
    DELETE FROM cartera_cliente     WHERE empresa_id = v.empresa_id;
    DELETE FROM clientes            WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_cli = ROW_COUNT;
    DELETE FROM cotizaciones        WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_cot = ROW_COUNT;
    PERFORM set_config('app.reset_empresa', '', true);
    RETURN jsonb_build_object('clientes', n_cli, 'operaciones', n_op, 'movimientos', n_mov, 'cotizaciones', n_cot, 'cambios', n_cam);
END $$;

-- Eliminar cliente sin operaciones: desvincula sus compras/ventas de mostrador (quedan con el nombre)
-- (ON DELETE SET NULL lo resuelve; el trigger de protección permite el cambio de cliente_id)
CREATE OR REPLACE FUNCTION fn_proteger_cambios() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF coalesce(current_setting('app.reset_empresa', true), '') = OLD.empresa_id::TEXT THEN RETURN OLD; END IF;
        RAISE EXCEPTION 'Las operaciones de cambio no se borran: anúlelas';
    END IF;
    IF (NEW.tipo, NEW.moneda_codigo, NEW.cantidad, NEW.cotizacion, NEW.total_gs, NEW.fecha, NEW.empresa_id)
          IS DISTINCT FROM (OLD.tipo, OLD.moneda_codigo, OLD.cantidad, OLD.cotizacion, OLD.total_gs, OLD.fecha, OLD.empresa_id) THEN
        RAISE EXCEPTION 'Las operaciones de cambio no se modifican: anúlelas';
    END IF;
    IF NEW.cliente_id IS NULL AND OLD.cliente_id IS NOT NULL AND NEW.anulada = OLD.anulada THEN
        RETURN NEW;   -- desvinculación por borrado del cliente
    END IF;
    IF coalesce(current_setting('app.via_funcion', true), 'off') <> 'on' THEN
        RAISE EXCEPTION 'Las operaciones de cambio no se modifican: anúlelas';
    END IF;
    RETURN NEW;
END $$;

-- Registrar con cliente opcional de la cartera
DROP FUNCTION IF EXISTS api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION api_registrar_cambio(
    p_tipo TEXT, p_moneda TEXT, p_cantidad NUMERIC, p_cotizacion NUMERIC,
    p_cliente_nombre TEXT DEFAULT NULL, p_cliente_doc TEXT DEFAULT NULL,
    p_metodo TEXT DEFAULT 'EFECTIVO', p_concepto TEXT DEFAULT NULL, p_cliente_id INT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; dec INT; q NUMERIC; tot NUMERIC; v_id BIGINT; c clientes;
BEGIN
    v := fn_perfil_actual();
    IF upper(p_tipo) NOT IN ('COMPRA','VENTA') THEN RAISE EXCEPTION 'Tipo inválido'; END IF;
    SELECT decimales INTO dec FROM monedas WHERE codigo = upper(p_moneda) AND codigo <> 'PYG';
    IF NOT FOUND THEN RAISE EXCEPTION 'Moneda inválida'; END IF;
    q := round(p_cantidad, dec);
    IF q IS NULL OR q <= 0 THEN RAISE EXCEPTION 'Cantidad inválida'; END IF;
    IF p_cotizacion IS NULL OR p_cotizacion <= 0 THEN RAISE EXCEPTION 'Cotización inválida'; END IF;
    IF p_cliente_id IS NOT NULL THEN
        SELECT * INTO c FROM clientes WHERE id = p_cliente_id AND empresa_id = v.empresa_id AND NOT eliminado;
        IF NOT FOUND THEN RAISE EXCEPTION 'Cliente inexistente'; END IF;
    END IF;
    tot := round(q * p_cotizacion, 0);
    INSERT INTO cambios (empresa_id, tipo, moneda_codigo, cantidad, cotizacion, total_gs, cliente_id, cliente_nombre, cliente_doc, metodo_pago, concepto, usuario_registro)
    VALUES (v.empresa_id, upper(p_tipo), upper(p_moneda), q, p_cotizacion, tot, c.id,
            coalesce(c.nombre_completo, nullif(trim(p_cliente_nombre), '')), coalesce(c.documento, nullif(trim(p_cliente_doc), '')),
            upper(coalesce(p_metodo, 'EFECTIVO')), nullif(trim(p_concepto), ''), v.email)
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

REVOKE EXECUTE ON FUNCTION api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT, INT), api_reiniciar_empresa(TEXT) TO authenticated;
