-- =====================================================================
-- CARTERA MULTIMONEDA — MIGRACIÓN v10
-- Pix (moneda de mostrador con taxa), pagos Pix/USDT, cotización Dólar→Reales,
-- venta eligiendo la compra (lote) de origen.
-- Ejecutar después de migracion_v9.sql (se puede re-ejecutar)
-- =====================================================================

-- 1. Monedas solo de mostrador (no crean cartera en los clientes)
ALTER TABLE monedas ADD COLUMN IF NOT EXISTS solo_mostrador BOOLEAN NOT NULL DEFAULT FALSE;

CREATE OR REPLACE FUNCTION crear_cartera_inicial() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO cartera_cliente (cliente_id, moneda_codigo, empresa_id)
    SELECT NEW.id, codigo, NEW.empresa_id FROM monedas WHERE NOT solo_mostrador;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION crear_cartera_nueva_moneda() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.solo_mostrador THEN RETURN NEW; END IF;
    INSERT INTO cartera_cliente (cliente_id, moneda_codigo, empresa_id)
    SELECT id, NEW.codigo, empresa_id FROM clientes
    ON CONFLICT (cliente_id, moneda_codigo) DO NOTHING;
    RETURN NEW;
END $$;

INSERT INTO monedas (codigo, nombre, simbolo, decimales, solo_mostrador)
VALUES ('PIX', 'Real vía Pix', 'R$', 2, TRUE)
ON CONFLICT (codigo) DO UPDATE SET solo_mostrador = TRUE;

-- 2. Métodos de pago: Pix y USDT
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT conrelid::regclass AS t, conname FROM pg_constraint
             WHERE contype = 'c' AND conrelid IN ('cambios'::regclass, 'movimientos_cartera'::regclass)
               AND pg_get_constraintdef(oid) ILIKE '%metodo_pago%' LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.t, r.conname);
    END LOOP;
END $$;
ALTER TABLE cambios ADD CONSTRAINT cambios_metodo_pago_check
    CHECK (metodo_pago IN ('EFECTIVO','TRANSFERENCIA','PIX','USDT','CHEQUE'));
ALTER TABLE movimientos_cartera ADD CONSTRAINT movimientos_cartera_metodo_pago_check
    CHECK (metodo_pago IN ('EFECTIVO','TRANSFERENCIA','PIX','USDT','CHEQUE','INTERNO'));

-- 3. Taxa (%) y lote de compra en los cambios
ALTER TABLE cambios ADD COLUMN IF NOT EXISTS taxa_pct NUMERIC(6,3) NOT NULL DEFAULT 0;
ALTER TABLE cambios ADD COLUMN IF NOT EXISTS lote_id BIGINT;      -- compra de la que sale la venta (sin FK: historial inmutable)
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cambios_taxa_rango') THEN
        ALTER TABLE cambios ADD CONSTRAINT cambios_taxa_rango CHECK (taxa_pct >= 0 AND taxa_pct < 100);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_proteger_cambios() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF coalesce(current_setting('app.reset_empresa', true), '') = OLD.empresa_id::TEXT THEN RETURN OLD; END IF;
        RAISE EXCEPTION 'Las operaciones de cambio no se borran: anúlelas';
    END IF;
    IF (NEW.tipo, NEW.moneda_codigo, NEW.cantidad, NEW.cotizacion, NEW.total_gs, NEW.fecha, NEW.empresa_id, NEW.taxa_pct, NEW.lote_id)
          IS DISTINCT FROM (OLD.tipo, OLD.moneda_codigo, OLD.cantidad, OLD.cotizacion, OLD.total_gs, OLD.fecha, OLD.empresa_id, OLD.taxa_pct, OLD.lote_id) THEN
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

-- 4. Registrar cambio: taxa y lote
--    Compra: la casa paga cantidad × cotización − taxa.  Venta: cobra cantidad × cotización + taxa.
DROP FUNCTION IF EXISTS api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT, INT);
CREATE OR REPLACE FUNCTION api_registrar_cambio(
    p_tipo TEXT, p_moneda TEXT, p_cantidad NUMERIC, p_cotizacion NUMERIC,
    p_cliente_nombre TEXT DEFAULT NULL, p_cliente_doc TEXT DEFAULT NULL,
    p_metodo TEXT DEFAULT 'EFECTIVO', p_concepto TEXT DEFAULT NULL, p_cliente_id INT DEFAULT NULL,
    p_taxa NUMERIC DEFAULT 0, p_lote_id BIGINT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; dec INT; q NUMERIC; tx NUMERIC; tot NUMERIC; v_id BIGINT; c clientes; tp TEXT; mo TEXT;
BEGIN
    v := fn_perfil_actual();
    tp := upper(p_tipo); mo := upper(p_moneda);
    IF tp NOT IN ('COMPRA','VENTA') THEN RAISE EXCEPTION 'Tipo inválido'; END IF;
    SELECT decimales INTO dec FROM monedas WHERE codigo = mo AND codigo <> 'PYG';
    IF NOT FOUND THEN RAISE EXCEPTION 'Moneda inválida'; END IF;
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
    tot := round(q * p_cotizacion * (CASE WHEN tp = 'COMPRA' THEN 1 - tx / 100 ELSE 1 + tx / 100 END), 0);
    IF tot <= 0 THEN RAISE EXCEPTION 'Total inválido'; END IF;
    INSERT INTO cambios (empresa_id, tipo, moneda_codigo, cantidad, cotizacion, total_gs, cliente_id, cliente_nombre, cliente_doc,
                         metodo_pago, concepto, usuario_registro, taxa_pct, lote_id)
    VALUES (v.empresa_id, tp, mo, q, p_cotizacion, tot, c.id,
            coalesce(c.nombre_completo, nullif(trim(p_cliente_nombre), '')), coalesce(c.documento, nullif(trim(p_cliente_doc), '')),
            upper(coalesce(p_metodo, 'EFECTIVO')), nullif(trim(p_concepto), ''), v.email, tx, p_lote_id)
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- 5. Cotizaciones cruzadas (Dólar → Reales: reales por 1 dólar)
CREATE TABLE IF NOT EXISTS cotizaciones_par (
    id               BIGSERIAL PRIMARY KEY,
    empresa_id       INT NOT NULL REFERENCES empresas(id),
    par              VARCHAR(7) NOT NULL CHECK (par IN ('USD/BRL')),
    compra           NUMERIC(18,6) NOT NULL CHECK (compra > 0),
    venta            NUMERIC(18,6) NOT NULL CHECK (venta > 0),
    usuario_registro TEXT NOT NULL,
    fecha            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (venta >= compra)
);
CREATE INDEX IF NOT EXISTS ix_cotpar ON cotizaciones_par (empresa_id, par, fecha DESC);
ALTER TABLE cotizaciones_par ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lectura_empresa ON cotizaciones_par;
CREATE POLICY lectura_empresa ON cotizaciones_par FOR SELECT TO authenticated
    USING (empresa_id = fn_empresa_actual() AND fn_empresa_vigente(empresa_id));
REVOKE ALL ON cotizaciones_par FROM anon, authenticated;
GRANT SELECT ON cotizaciones_par TO authenticated;

-- Guardar todo: acepta monedas y el par USD/BRL
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

-- 6. Reinicio: incluye cotizaciones cruzadas
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
    DELETE FROM cotizaciones_par    WHERE empresa_id = v.empresa_id;
    PERFORM set_config('app.reset_empresa', '', true);
    RETURN jsonb_build_object('clientes', n_cli, 'operaciones', n_op, 'movimientos', n_mov, 'cotizaciones', n_cot, 'cambios', n_cam);
END $$;

REVOKE EXECUTE ON FUNCTION api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT, INT, NUMERIC, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api_registrar_cambio(TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT, INT, NUMERIC, BIGINT),
                          api_set_cotizaciones(JSONB), api_reiniciar_empresa(TEXT) TO authenticated;
