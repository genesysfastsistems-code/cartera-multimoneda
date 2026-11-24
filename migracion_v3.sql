-- =====================================================================
-- CARTERA MULTIMONEDA — MIGRACIÓN v3
-- Cotizaciones del día, recibos, panel, gestión de usuarios, datos de la casa
-- Ejecutar UNA vez en Supabase > SQL Editor (después de cartera_supabase.sql)
-- =====================================================================

-- 1. Datos de la casa (encabezado de recibos)
CREATE TABLE IF NOT EXISTS config_casa (
    id          INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    nombre      TEXT NOT NULL DEFAULT 'Casa de Cambio',
    ruc         TEXT,
    direccion   TEXT,
    telefono    TEXT,
    pie_recibo  TEXT DEFAULT 'Conserve este comprobante.'
);
INSERT INTO config_casa (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- 2. Cotizaciones (en guaraníes por unidad; historial completo)
CREATE TABLE IF NOT EXISTS cotizaciones (
    id               BIGSERIAL PRIMARY KEY,
    moneda_codigo    VARCHAR(3) NOT NULL REFERENCES monedas(codigo) CHECK (moneda_codigo <> 'PYG'),
    compra           NUMERIC(18,6) NOT NULL CHECK (compra > 0),
    venta            NUMERIC(18,6) NOT NULL CHECK (venta > 0),
    usuario_registro TEXT NOT NULL,
    fecha            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (venta >= compra)
);
CREATE INDEX IF NOT EXISTS idx_cotiz_moneda_fecha ON cotizaciones (moneda_codigo, fecha DESC);

CREATE OR REPLACE VIEW v_cotizacion_actual AS
SELECT DISTINCT ON (moneda_codigo) moneda_codigo, compra, venta, usuario_registro, fecha
FROM cotizaciones
ORDER BY moneda_codigo, fecha DESC, id DESC;

-- 3. Operaciones con detalle (panel y recibos)
CREATE OR REPLACE VIEW v_operaciones AS
SELECT o.id, o.fecha, o.tipo, o.cliente_id, c.nombre_completo, c.documento, c.tipo_persona,
       o.concepto, o.usuario_registro, o.operacion_anulada_id,
       EXISTS (SELECT 1 FROM operaciones a WHERE a.operacion_anulada_id = o.id) AS anulada,
       (SELECT jsonb_agg(jsonb_build_object(
                 'moneda', cc.moneda_codigo, 'tipo', m.tipo_operacion,
                 'importe', fn_signo(m.tipo_operacion) * m.monto, 'saldo', m.saldo_nuevo,
                 'metodo', m.metodo_pago, 'comprobante', m.comprobante_ref, 'tasa', m.tasa_cambio)
               ORDER BY m.id)
        FROM movimientos_cartera m JOIN cartera_cliente cc ON cc.id = m.cartera_id
        WHERE m.operacion_id = o.id) AS movimientos
FROM operaciones o
JOIN clientes c ON c.id = o.cliente_id;

-- 4. API: cotizaciones y configuración
CREATE OR REPLACE FUNCTION api_set_cotizacion(p_moneda TEXT, p_compra NUMERIC, p_venta NUMERIC)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; v_id BIGINT;
BEGIN
    v := fn_perfil_actual(ARRAY['SUPERVISOR','ADMIN']);
    IF p_venta < p_compra THEN RAISE EXCEPTION 'La venta no puede ser menor que la compra'; END IF;
    INSERT INTO cotizaciones (moneda_codigo, compra, venta, usuario_registro)
    VALUES (upper(p_moneda), p_compra, p_venta, v.email) RETURNING id INTO v_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION api_set_config(p_nombre TEXT, p_ruc TEXT, p_direccion TEXT, p_telefono TEXT, p_pie TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM fn_perfil_actual(ARRAY['ADMIN']);
    IF coalesce(trim(p_nombre), '') = '' THEN RAISE EXCEPTION 'El nombre es obligatorio'; END IF;
    UPDATE config_casa SET nombre = trim(p_nombre), ruc = nullif(trim(p_ruc), ''),
        direccion = nullif(trim(p_direccion), ''), telefono = nullif(trim(p_telefono), ''),
        pie_recibo = nullif(trim(p_pie), '')
    WHERE id = 1;
END $$;

-- 5. API: gestión de usuarios (solo ADMIN)
CREATE OR REPLACE FUNCTION api_listar_usuarios()
RETURNS TABLE (email TEXT, nombre TEXT, rol TEXT, activo BOOLEAN, ultimo_ingreso TIMESTAMPTZ, tiene_cuenta BOOLEAN)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM fn_perfil_actual(ARRAY['ADMIN']);
    RETURN QUERY
    SELECT p.email, p.nombre, p.rol::TEXT, p.activo, u.last_sign_in_at, (u.id IS NOT NULL)
    FROM perfiles p LEFT JOIN auth.users u ON lower(u.email) = p.email
    ORDER BY p.activo DESC, p.nombre;
END $$;

CREATE OR REPLACE FUNCTION api_crear_usuario(p_email TEXT, p_nombre TEXT, p_rol TEXT, p_password TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e TEXT := lower(trim(p_email)); uid UUID;
BEGIN
    PERFORM fn_perfil_actual(ARRAY['ADMIN']);
    IF e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'Email inválido'; END IF;
    IF coalesce(trim(p_nombre), '') = '' THEN RAISE EXCEPTION 'Nombre obligatorio'; END IF;
    IF upper(p_rol) NOT IN ('CAJERO','SUPERVISOR','ADMIN') THEN RAISE EXCEPTION 'Rol inválido'; END IF;
    IF EXISTS (SELECT 1 FROM perfiles WHERE email = e) THEN RAISE EXCEPTION 'Ese usuario ya existe'; END IF;

    SELECT id INTO uid FROM auth.users WHERE lower(email) = e;
    IF uid IS NULL THEN
        IF length(coalesce(p_password, '')) < 8 THEN
            RAISE EXCEPTION 'La contraseña debe tener al menos 8 caracteres';
        END IF;
        uid := gen_random_uuid();
        INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
            confirmation_token, email_change, email_change_token_new, recovery_token)
        VALUES ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', e,
            extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('nombre', trim(p_nombre)),
            now(), now(), '', '', '', '');
        INSERT INTO auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
        VALUES (gen_random_uuid(), uid, uid::TEXT,
            jsonb_build_object('sub', uid::TEXT, 'email', e, 'email_verified', true),
            'email', now(), now(), now());
    END IF;
    INSERT INTO perfiles (email, nombre, rol) VALUES (e, trim(p_nombre), upper(p_rol));
END $$;

CREATE OR REPLACE FUNCTION api_actualizar_usuario(p_email TEXT, p_nombre TEXT, p_rol TEXT, p_activo BOOLEAN, p_password TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; e TEXT := lower(trim(p_email));
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE email = e) THEN RAISE EXCEPTION 'Usuario inexistente'; END IF;
    IF e = v.email AND (upper(p_rol) <> 'ADMIN' OR NOT p_activo) THEN
        RAISE EXCEPTION 'No puede quitarse a sí mismo el rol ADMIN ni desactivarse';
    END IF;
    IF upper(p_rol) NOT IN ('CAJERO','SUPERVISOR','ADMIN') THEN RAISE EXCEPTION 'Rol inválido'; END IF;
    UPDATE perfiles SET nombre = trim(p_nombre), rol = upper(p_rol), activo = p_activo WHERE email = e;
    IF coalesce(p_password, '') <> '' THEN
        IF length(p_password) < 8 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 8 caracteres'; END IF;
        UPDATE auth.users SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
               updated_at = now()
        WHERE lower(email) = e;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION api_config_casa()
RETURNS SETOF config_casa LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT * FROM config_casa WHERE fn_es_usuario();
$$;

-- 6. Seguridad
ALTER VIEW v_cotizacion_actual SET (security_invoker = true);
ALTER VIEW v_operaciones       SET (security_invoker = true);

ALTER TABLE config_casa  ENABLE ROW LEVEL SECURITY;
ALTER TABLE cotizaciones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lectura_usuarios ON config_casa;
DROP POLICY IF EXISTS lectura_usuarios ON cotizaciones;
CREATE POLICY lectura_usuarios ON config_casa  FOR SELECT TO authenticated USING (fn_es_usuario());
CREATE POLICY lectura_usuarios ON cotizaciones FOR SELECT TO authenticated USING (fn_es_usuario());

REVOKE ALL ON config_casa, cotizaciones, v_cotizacion_actual, v_operaciones FROM anon, authenticated;
REVOKE ALL ON SEQUENCE cotizaciones_id_seq FROM anon, authenticated;
GRANT SELECT ON config_casa, cotizaciones, v_cotizacion_actual, v_operaciones TO authenticated;

REVOKE EXECUTE ON FUNCTION api_set_cotizacion(TEXT, NUMERIC, NUMERIC), api_set_config(TEXT, TEXT, TEXT, TEXT, TEXT),
    api_listar_usuarios(), api_crear_usuario(TEXT, TEXT, TEXT, TEXT),
    api_actualizar_usuario(TEXT, TEXT, TEXT, BOOLEAN, TEXT), api_config_casa()
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api_set_cotizacion(TEXT, NUMERIC, NUMERIC), api_set_config(TEXT, TEXT, TEXT, TEXT, TEXT),
    api_listar_usuarios(), api_crear_usuario(TEXT, TEXT, TEXT, TEXT),
    api_actualizar_usuario(TEXT, TEXT, TEXT, BOOLEAN, TEXT), api_config_casa()
    TO authenticated;
