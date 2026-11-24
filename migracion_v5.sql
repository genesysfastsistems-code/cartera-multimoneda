-- =====================================================================
-- CARTERA MULTIMONEDA — MIGRACIÓN v5: logo de empresa + guardado masivo de cotizaciones
-- Ejecutar UNA vez después de migracion_v4.sql
-- =====================================================================

ALTER TABLE empresas ADD COLUMN IF NOT EXISTS logo TEXT;

-- Logo como imagen embebida (data URL), redimensionada por la app (máx. ~300 KB)
CREATE OR REPLACE FUNCTION api_set_logo(p_logo TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    IF p_logo IS NOT NULL THEN
        IF p_logo !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$' THEN
            RAISE EXCEPTION 'Formato de imagen no válido (use PNG, JPG o WEBP)';
        END IF;
        IF length(p_logo) > 400000 THEN
            RAISE EXCEPTION 'La imagen es demasiado grande';
        END IF;
    END IF;
    UPDATE empresas SET logo = p_logo WHERE id = v.empresa_id;
END $$;

-- Guarda varias cotizaciones en una sola operación (todo o nada)
-- p_items: [{"moneda":"USD","compra":7250,"venta":7350}, ...]
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
        IF NOT EXISTS (SELECT 1 FROM monedas WHERE codigo = m) OR m = 'PYG' THEN
            RAISE EXCEPTION 'Moneda inválida: %', m;
        END IF;
        IF c IS NULL OR vt IS NULL OR c <= 0 OR vt <= 0 THEN
            RAISE EXCEPTION '%: compra y venta deben ser mayores a cero', m;
        END IF;
        IF vt < c THEN RAISE EXCEPTION '%: la venta no puede ser menor que la compra', m; END IF;
        INSERT INTO cotizaciones (empresa_id, moneda_codigo, compra, venta, usuario_registro)
        VALUES (v.empresa_id, m, c, vt, v.email);
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;

REVOKE EXECUTE ON FUNCTION api_set_logo(TEXT), api_set_cotizaciones(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api_set_logo(TEXT), api_set_cotizaciones(JSONB) TO authenticated;
