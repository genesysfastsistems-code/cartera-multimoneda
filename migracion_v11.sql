-- =====================================================================
-- CARTERA MULTIMONEDA — MIGRACIÓN v11
-- USDT como moneda de cliente, taxa Pix configurable, compra/venta pagada en reales o Pix
-- Ejecutar después de migracion_v10.sql (se puede re-ejecutar)
-- =====================================================================

-- 1. USDT (código interno UST; crea cartera USDT en todos los clientes)
INSERT INTO monedas (codigo, nombre, simbolo, decimales, solo_mostrador)
VALUES ('UST', 'USDT (Tether)', 'USDT', 2, FALSE)
ON CONFLICT (codigo) DO NOTHING;

-- 2. Taxa Pix por empresa
ALTER TABLE empresas ADD COLUMN IF NOT EXISTS taxa_pix NUMERIC(6,3) NOT NULL DEFAULT 5;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'empresas_taxa_pix_rango') THEN
        ALTER TABLE empresas ADD CONSTRAINT empresas_taxa_pix_rango CHECK (taxa_pix >= 0 AND taxa_pix < 100);
    END IF;
END $$;

-- 3. Moneda en que se paga (PYG por defecto; BRL o PIX para dólar x reales)
ALTER TABLE cambios ADD COLUMN IF NOT EXISTS moneda_pago VARCHAR(3) NOT NULL DEFAULT 'PYG' REFERENCES monedas(codigo);
ALTER TABLE cambios ADD COLUMN IF NOT EXISTS total_pago NUMERIC(18,4);
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cambios_pago_distinto') THEN
        ALTER TABLE cambios ADD CONSTRAINT cambios_pago_distinto CHECK (moneda_pago <> moneda_codigo);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_proteger_cambios() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF coalesce(current_setting('app.reset_empresa', true), '') = OLD.empresa_id::TEXT THEN RETURN OLD; END IF;
        RAISE EXCEPTION 'Las operaciones de cambio no se borran: anúlelas';
    END IF;
    IF (NEW.tipo, NEW.moneda_codigo, NEW.cantidad, NEW.cotizacion, NEW.total_gs, NEW.fecha, NEW.empresa_id, NEW.taxa_pct, NEW.lote_id, NEW.moneda_pago, NEW.total_pago)
          IS DISTINCT FROM (OLD.tipo, OLD.moneda_codigo, OLD.cantidad, OLD.cotizacion, OLD.total_gs, OLD.fecha, OLD.empresa_id, OLD.taxa_pct, OLD.lote_id, OLD.moneda_pago, OLD.total_pago) THEN
        RAISE EXCEPTION 'Las operaciones de cambio no se modifican: anúlelas';
    END IF;
    IF NEW.cliente_id IS NULL AND OLD.cliente_id IS NOT NULL AND NEW.anulada = OLD.anulada THEN
        RETURN NEW;
    END IF;
    IF coalesce(current_setting('app.via_funcion', true), 'off') <> 'on' THEN
        RAISE EXCEPTION 'Las operaciones de cambio no se modifican: anúlelas';
    END IF;
    RETURN NEW;
END $$;

-- Última cotización de compra (Gs.) de la empresa
CREATE OR REPLACE FUNCTION fn_cot_compra(p_empresa INT, p_moneda TEXT) RETURNS NUMERIC
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT compra FROM cotizaciones WHERE empresa_id = p_empresa AND moneda_codigo = p_moneda ORDER BY fecha DESC, id DESC LIMIT 1
$$;
REVOKE EXECUTE ON FUNCTION fn_cot_compra(INT, TEXT) FROM PUBLIC, anon, authenticated;

-- 4. Registrar cambio
--    p_moneda_pago = PYG: cotización en Gs. por unidad.
--    p_moneda_pago = BRL/PIX: cotización en reales por unidad (dólar x reales).
--    Compra: la casa entrega cantidad × cotización − taxa.  Venta: recibe cantidad × cotización + taxa.
DROP FUNCTION IF EXISTS api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT, INT, NUMERIC, BIGINT);
CREATE OR REPLACE FUNCTION api_registrar_cambio(
    p_tipo TEXT, p_moneda TEXT, p_cantidad NUMERIC, p_cotizacion NUMERIC,
    p_cliente_nombre TEXT DEFAULT NULL, p_cliente_doc TEXT DEFAULT NULL,
    p_metodo TEXT DEFAULT 'EFECTIVO', p_concepto TEXT DEFAULT NULL, p_cliente_id INT DEFAULT NULL,
    p_taxa NUMERIC DEFAULT 0, p_lote_id BIGINT DEFAULT NULL, p_moneda_pago TEXT DEFAULT 'PYG'
) RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; dec INT; decp INT; q NUMERIC; tx NUMERIC; f NUMERIC; tot NUMERIC; totp NUMERIC; cg NUMERIC;
        v_id BIGINT; c clientes; tp TEXT; mo TEXT; mp TEXT;
BEGIN
    v := fn_perfil_actual();
    tp := upper(p_tipo); mo := upper(p_moneda); mp := upper(coalesce(nullif(trim(p_moneda_pago), ''), 'PYG'));
    IF tp NOT IN ('COMPRA','VENTA') THEN RAISE EXCEPTION 'Tipo inválido'; END IF;
    SELECT decimales INTO dec FROM monedas WHERE codigo = mo AND codigo <> 'PYG';
    IF NOT FOUND THEN RAISE EXCEPTION 'Moneda inválida'; END IF;
    IF mp NOT IN ('PYG','BRL','PIX') OR mp = mo OR (mp <> 'PYG' AND mo IN ('BRL','PIX')) THEN
        RAISE EXCEPTION 'Moneda de pago inválida';
    END IF;
    SELECT decimales INTO decp FROM monedas WHERE codigo = mp;
    q := round(p_cantidad, dec);
    IF q IS NULL OR q <= 0 THEN RAISE EXCEPTION 'Cantidad inválida'; END IF;
    IF p_cotizacion IS NULL OR p_cotizacion <= 0 THEN RAISE EXCEPTION 'Cotización inválida'; END IF;
    tx := round(coalesce(p_taxa, 0), 3);
    IF tx < 0 OR tx >= 100 THEN RAISE EXCEPTION 'Taxa inválida (0 a 99,99 %%)'; END IF;
    IF p_cliente_id IS NOT NULL THEN
        SELECT * INTO c FROM clientes WHERE id = p_cliente_id AND empresa_id = v.empresa_id AND NOT eliminado;
        IF NOT FOUND THEN RAISE EXCEPTION 'Cliente inexistente'; END IF;
    END IF;
    IF p_lote_id IS NOT NULL THEN
        IF tp <> 'VENTA' THEN RAISE EXCEPTION 'Solo una venta puede indicar la compra de origen'; END IF;
        IF NOT EXISTS (SELECT 1 FROM cambios WHERE id = p_lote_id AND empresa_id = v.empresa_id
                       AND tipo = 'COMPRA' AND moneda_codigo = mo AND NOT anulada) THEN
            RAISE EXCEPTION 'La compra elegida no existe, está anulada o es de otra moneda';
        END IF;
    END IF;
    f := CASE WHEN tp = 'COMPRA' THEN 1 - tx / 100 ELSE 1 + tx / 100 END;
    IF mp = 'PYG' THEN
        tot := round(q * p_cotizacion * f, 0); totp := NULL;
    ELSE
        totp := round(q * p_cotizacion * f, decp);
        IF totp <= 0 THEN RAISE EXCEPTION 'Total inválido'; END IF;
        -- equivalente en Gs. de lo que entrega el cliente (para stock y ganancia)
        IF tp = 'COMPRA' THEN
            cg := fn_cot_compra(v.empresa_id, mo);
            IF cg IS NULL THEN RAISE EXCEPTION 'Cargue la cotización en guaraníes de %', mo; END IF;
            tot := round(q * cg, 0);
        ELSE
            cg := coalesce(fn_cot_compra(v.empresa_id, mp), fn_cot_compra(v.empresa_id, 'BRL'));
            IF cg IS NULL THEN RAISE EXCEPTION 'Cargue la cotización en guaraníes del real'; END IF;
            tot := round(totp * cg, 0);
        END IF;
    END IF;
    IF tot <= 0 THEN RAISE EXCEPTION 'Total inválido'; END IF;
    INSERT INTO cambios (empresa_id, tipo, moneda_codigo, cantidad, cotizacion, total_gs, cliente_id, cliente_nombre, cliente_doc,
                         metodo_pago, concepto, usuario_registro, taxa_pct, lote_id, moneda_pago, total_pago)
    VALUES (v.empresa_id, tp, mo, q, p_cotizacion, tot, c.id,
            coalesce(c.nombre_completo, nullif(trim(p_cliente_nombre), '')), coalesce(c.documento, nullif(trim(p_cliente_doc), '')),
            upper(coalesce(p_metodo, 'EFECTIVO')), nullif(trim(p_concepto), ''), v.email, tx, p_lote_id, mp, totp)
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- 5. Guardar todo: también la taxa Pix (item {"moneda":"TAXA_PIX","compra":5,"venta":5})
CREATE OR REPLACE FUNCTION api_set_cotizaciones(p_items JSONB)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; it JSONB; m TEXT; c NUMERIC; vt NUMERIC; n INT := 0;
BEGIN
    v := fn_perfil_actual(ARRAY['SUPERVISOR','ADMIN']);
    IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'No hay cotizaciones para guardar';
    END IF;
    FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        m  := upper(it ->> 'moneda');
        c  := (it ->> 'compra')::NUMERIC;
        vt := (it ->> 'venta')::NUMERIC;
        IF m = 'TAXA_PIX' THEN
            IF c IS NULL OR c < 0 OR c >= 100 THEN RAISE EXCEPTION 'Taxa Pix inválida (0 a 99,99 %%)'; END IF;
            UPDATE empresas SET taxa_pix = round(c, 3) WHERE id = v.empresa_id;
            n := n + 1;
            CONTINUE;
        END IF;
        IF c IS NULL OR vt IS NULL OR c <= 0 OR vt <= 0 THEN
            RAISE EXCEPTION '%: compra y venta deben ser mayores a cero', m;
        END IF;
        IF vt < c THEN RAISE EXCEPTION '%: la venta no puede ser menor que la compra', m; END IF;
        IF m = 'USD/BRL' THEN
            INSERT INTO cotizaciones_par (empresa_id, par, compra, venta, usuario_registro)
            VALUES (v.empresa_id, m, c, vt, v.email);
        ELSE
            IF NOT EXISTS (SELECT 1 FROM monedas WHERE codigo = m) OR m = 'PYG' THEN
                RAISE EXCEPTION 'Moneda inválida: %', m;
            END IF;
            INSERT INTO cotizaciones (empresa_id, moneda_codigo, compra, venta, usuario_registro)
            VALUES (v.empresa_id, m, c, vt, v.email);
        END IF;
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;

REVOKE EXECUTE ON FUNCTION api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT, INT, NUMERIC, BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT, INT, NUMERIC, BIGINT, TEXT),
                          api_set_cotizaciones(JSONB) TO authenticated;
