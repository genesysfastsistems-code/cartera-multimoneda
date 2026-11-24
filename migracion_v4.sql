-- =====================================================================
-- CARTERA MULTIMONEDA — MIGRACIÓN v4: MULTIEMPRESA + MEMBRESÍAS
-- * Cada casa de cambio es una "empresa" aislada (RLS por empresa)
-- * Panel de desarrollador (rol DEV): vende planes PRUEBA / MENSUAL / ANUAL / UNICO
-- * Ingreso por nombre de usuario (sin email): usuario -> usuario@cmm.local
-- * Bloqueo automático al vencer la membresía
-- Ejecutar UNA vez después de migracion_v3.sql
-- =====================================================================

-- ---------- 1. Configuración global del proveedor ----------
CREATE TABLE IF NOT EXISTS app_config (
    id               INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    soporte_nombre   TEXT DEFAULT 'Soporte',
    soporte_telefono TEXT,
    soporte_email    TEXT,
    moneda_precios   VARCHAR(3) NOT NULL DEFAULT 'USD',
    precio_mensual   NUMERIC(18,2) NOT NULL DEFAULT 0,
    precio_anual     NUMERIC(18,2) NOT NULL DEFAULT 0,
    precio_unico     NUMERIC(18,2) NOT NULL DEFAULT 0,
    dias_prueba      INT NOT NULL DEFAULT 7 CHECK (dias_prueba BETWEEN 1 AND 90)
);
INSERT INTO app_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- ---------- 2. Empresas (clientes del desarrollador) ----------
CREATE TABLE IF NOT EXISTS empresas (
    id            SERIAL PRIMARY KEY,
    nombre        TEXT NOT NULL,
    ruc           TEXT,
    direccion     TEXT,
    telefono      TEXT,
    email_contacto TEXT,
    pie_recibo    TEXT DEFAULT 'Conserve este comprobante.',
    plan          VARCHAR(10) NOT NULL DEFAULT 'PRUEBA' CHECK (plan IN ('PRUEBA','MENSUAL','ANUAL','UNICO')),
    vence         DATE,
    activo        BOOLEAN NOT NULL DEFAULT TRUE,
    max_usuarios  INT NOT NULL DEFAULT 3 CHECK (max_usuarios BETWEEN 1 AND 500),
    notas         TEXT,
    creado        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (plan = 'UNICO' OR vence IS NOT NULL)
);

-- Empresa 1 recibe los datos existentes (toma nombre de config_casa si existe)
DO $$
BEGIN
    IF to_regclass('public.config_casa') IS NOT NULL THEN
        INSERT INTO empresas (id, nombre, ruc, direccion, telefono, pie_recibo, plan, vence)
        SELECT 1, coalesce(c.nombre, 'Empresa demo'), c.ruc, c.direccion, c.telefono, c.pie_recibo, 'PRUEBA', current_date + 30
        FROM (SELECT 1) x LEFT JOIN config_casa c ON c.id = 1
        ON CONFLICT (id) DO NOTHING;
    ELSE
        INSERT INTO empresas (id, nombre, plan, vence) VALUES (1, 'Empresa demo', 'PRUEBA', current_date + 30)
        ON CONFLICT (id) DO NOTHING;
    END IF;
END $$;
SELECT setval('empresas_id_seq', greatest((SELECT max(id) FROM empresas), 1));
DROP TABLE IF EXISTS config_casa CASCADE;
DROP FUNCTION IF EXISTS api_config_casa();

CREATE TABLE IF NOT EXISTS pagos_membresia (
    id               BIGSERIAL PRIMARY KEY,
    empresa_id       INT NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    plan             VARCHAR(10) NOT NULL CHECK (plan IN ('PRUEBA','MENSUAL','ANUAL','UNICO')),
    monto            NUMERIC(18,2) NOT NULL CHECK (monto >= 0),
    moneda           VARCHAR(3) NOT NULL DEFAULT 'USD',
    vence_anterior   DATE,
    vence_nuevo      DATE,
    nota             TEXT,
    usuario_registro TEXT NOT NULL,
    fecha            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- 3. empresa_id en todas las tablas operativas ----------
ALTER TABLE clientes            ADD COLUMN IF NOT EXISTS empresa_id INT REFERENCES empresas(id);
ALTER TABLE cartera_cliente     ADD COLUMN IF NOT EXISTS empresa_id INT REFERENCES empresas(id);
ALTER TABLE operaciones         ADD COLUMN IF NOT EXISTS empresa_id INT REFERENCES empresas(id);
ALTER TABLE movimientos_cartera ADD COLUMN IF NOT EXISTS empresa_id INT REFERENCES empresas(id);
ALTER TABLE cotizaciones        ADD COLUMN IF NOT EXISTS empresa_id INT REFERENCES empresas(id);
ALTER TABLE perfiles            ADD COLUMN IF NOT EXISTS empresa_id INT REFERENCES empresas(id);

-- Rellenar datos existentes (las tablas inmutables se habilitan un instante)
ALTER TABLE operaciones         DISABLE TRIGGER trg_op_inmutable;
ALTER TABLE movimientos_cartera DISABLE TRIGGER trg_mov_inmutable;
ALTER TABLE cartera_cliente     DISABLE TRIGGER trg_proteger_saldo;
UPDATE clientes            SET empresa_id = 1 WHERE empresa_id IS NULL;
UPDATE cartera_cliente     SET empresa_id = 1 WHERE empresa_id IS NULL;
UPDATE operaciones         SET empresa_id = 1 WHERE empresa_id IS NULL;
UPDATE movimientos_cartera SET empresa_id = 1 WHERE empresa_id IS NULL;
UPDATE cotizaciones        SET empresa_id = 1 WHERE empresa_id IS NULL;
ALTER TABLE operaciones         ENABLE TRIGGER trg_op_inmutable;
ALTER TABLE movimientos_cartera ENABLE TRIGGER trg_mov_inmutable;
ALTER TABLE cartera_cliente     ENABLE TRIGGER trg_proteger_saldo;

ALTER TABLE clientes            ALTER COLUMN empresa_id SET NOT NULL;
ALTER TABLE cartera_cliente     ALTER COLUMN empresa_id SET NOT NULL;
ALTER TABLE operaciones         ALTER COLUMN empresa_id SET NOT NULL;
ALTER TABLE movimientos_cartera ALTER COLUMN empresa_id SET NOT NULL;
ALTER TABLE cotizaciones        ALTER COLUMN empresa_id SET NOT NULL;

-- Documento único por empresa (no global)
ALTER TABLE clientes DROP CONSTRAINT IF EXISTS clientes_documento_key;
DROP INDEX IF EXISTS ux_clientes_empresa_doc;
CREATE UNIQUE INDEX ux_clientes_empresa_doc ON clientes (empresa_id, documento);
CREATE INDEX IF NOT EXISTS ix_clientes_empresa  ON clientes (empresa_id);
CREATE INDEX IF NOT EXISTS ix_cartera_empresa   ON cartera_cliente (empresa_id);
CREATE INDEX IF NOT EXISTS ix_oper_empresa      ON operaciones (empresa_id, id DESC);
CREATE INDEX IF NOT EXISTS ix_mov_empresa       ON movimientos_cartera (empresa_id);
CREATE INDEX IF NOT EXISTS ix_cotiz_empresa     ON cotizaciones (empresa_id, moneda_codigo, fecha DESC);

-- Perfiles: rol DEV sin empresa; el resto con empresa
ALTER TABLE perfiles DROP CONSTRAINT IF EXISTS perfiles_rol_check;
ALTER TABLE perfiles ADD CONSTRAINT perfiles_rol_check CHECK (rol IN ('CAJERO','SUPERVISOR','ADMIN','DEV'));
ALTER TABLE perfiles ALTER COLUMN rol TYPE VARCHAR(10);
UPDATE perfiles SET rol = 'DEV', empresa_id = NULL WHERE email = 'genesysfastsistems@gmail.com';
UPDATE perfiles SET empresa_id = 1 WHERE rol <> 'DEV' AND empresa_id IS NULL;
ALTER TABLE perfiles DROP CONSTRAINT IF EXISTS perfiles_empresa_rol;
ALTER TABLE perfiles ADD CONSTRAINT perfiles_empresa_rol CHECK ((rol = 'DEV') = (empresa_id IS NULL));

-- ---------- 4. Triggers que heredan empresa_id ----------
CREATE OR REPLACE FUNCTION crear_cartera_inicial() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO cartera_cliente (cliente_id, moneda_codigo, empresa_id)
    SELECT NEW.id, codigo, NEW.empresa_id FROM monedas;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION crear_cartera_nueva_moneda() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO cartera_cliente (cliente_id, moneda_codigo, empresa_id)
    SELECT id, NEW.codigo, empresa_id FROM clientes
    ON CONFLICT (cliente_id, moneda_codigo) DO NOTHING;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION fn_empresa_desde_cliente() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    SELECT empresa_id INTO NEW.empresa_id FROM clientes WHERE id = NEW.cliente_id;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_oper_empresa ON operaciones;
CREATE TRIGGER trg_oper_empresa BEFORE INSERT ON operaciones
FOR EACH ROW EXECUTE FUNCTION fn_empresa_desde_cliente();

CREATE OR REPLACE FUNCTION fn_empresa_desde_cartera() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    SELECT empresa_id INTO NEW.empresa_id FROM cartera_cliente WHERE id = NEW.cartera_id;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_mov_empresa ON movimientos_cartera;
CREATE TRIGGER trg_mov_empresa BEFORE INSERT ON movimientos_cartera
FOR EACH ROW EXECUTE FUNCTION fn_empresa_desde_cartera();

-- ---------- 5. Identidad, vigencia y helpers ----------
CREATE OR REPLACE FUNCTION fn_hoy() RETURNS DATE LANGUAGE sql STABLE AS $$
    SELECT (now() AT TIME ZONE 'America/Asuncion')::date
$$;

CREATE OR REPLACE FUNCTION fn_email_de_usuario(p TEXT) RETURNS TEXT LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE u TEXT := lower(trim(coalesce(p, '')));
BEGIN
    IF position('@' IN u) > 0 THEN RETURN u; END IF;
    IF u !~ '^[a-z0-9][a-z0-9._-]{2,39}$' THEN
        RAISE EXCEPTION 'Usuario inválido: use 3 a 40 letras minúsculas, números, punto, guion o guion bajo';
    END IF;
    RETURN u || '@cmm.local';
END $$;

CREATE OR REPLACE FUNCTION fn_empresa_vigente(p_id INT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT coalesce((SELECT activo AND (plan = 'UNICO' OR vence >= fn_hoy()) FROM empresas WHERE id = p_id), false)
$$;

CREATE OR REPLACE FUNCTION fn_perfil_base() RETURNS perfiles
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    SELECT * INTO v FROM perfiles WHERE email = lower(auth.jwt() ->> 'email') AND activo;
    IF NOT FOUND THEN RAISE EXCEPTION 'Usuario sin perfil habilitado'; END IF;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION fn_perfil_actual(p_roles TEXT[] DEFAULT NULL) RETURNS perfiles
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_base();
    IF v.rol = 'DEV' THEN RAISE EXCEPTION 'Acción no disponible desde el panel de desarrollador'; END IF;
    IF NOT fn_empresa_vigente(v.empresa_id) THEN
        RAISE EXCEPTION 'MEMBRESIA_VENCIDA: la membresía de su empresa no está vigente';
    END IF;
    IF p_roles IS NOT NULL AND NOT (v.rol = ANY (p_roles)) THEN
        RAISE EXCEPTION 'Permiso insuficiente (rol %)', v.rol;
    END IF;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION fn_dev() RETURNS perfiles
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_base();
    IF v.rol <> 'DEV' THEN RAISE EXCEPTION 'Solo el desarrollador puede hacer esto'; END IF;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION fn_empresa_actual() RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT empresa_id FROM perfiles WHERE email = lower(auth.jwt() ->> 'email') AND activo
$$;

CREATE OR REPLACE FUNCTION fn_es_usuario() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (SELECT 1 FROM perfiles p WHERE p.email = lower(auth.jwt() ->> 'email') AND p.activo
                   AND (p.rol = 'DEV' OR fn_empresa_vigente(p.empresa_id)))
$$;

-- Crea la cuenta de acceso (Supabase Auth) sin enviar emails
CREATE OR REPLACE FUNCTION fn_crear_cuenta(p_email TEXT, p_password TEXT, p_nombre TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID;
BEGIN
    SELECT id INTO uid FROM auth.users WHERE lower(email) = p_email;
    IF uid IS NOT NULL THEN
        IF coalesce(p_password, '') <> '' THEN
            UPDATE auth.users SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() WHERE id = uid;
        END IF;
        RETURN uid;
    END IF;
    IF length(coalesce(p_password, '')) < 8 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 8 caracteres'; END IF;
    uid := gen_random_uuid();
    INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, email_change, email_change_token_new, recovery_token)
    VALUES ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', p_email,
        extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('nombre', p_nombre),
        now(), now(), '', '', '', '');
    INSERT INTO auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    VALUES (gen_random_uuid(), uid, uid::TEXT,
        jsonb_build_object('sub', uid::TEXT, 'email', p_email, 'email_verified', true), 'email', now(), now(), now());
    RETURN uid;
END $$;

CREATE OR REPLACE FUNCTION fn_set_password(p_email TEXT, p_password TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF length(coalesce(p_password, '')) < 8 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 8 caracteres'; END IF;
    UPDATE auth.users SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
    WHERE lower(email) = p_email;
    IF NOT FOUND THEN RAISE EXCEPTION 'La cuenta de acceso no existe'; END IF;
END $$;

-- Verifica que un cliente pertenezca a la empresa del usuario
CREATE OR REPLACE FUNCTION fn_check_cliente(p_cliente INT, p_empresa INT) RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente AND empresa_id = p_empresa) THEN
        RAISE EXCEPTION 'Cliente inexistente';
    END IF;
END $$;

-- ---------- 6. Vistas ----------
DROP VIEW IF EXISTS v_cotizacion_actual;
CREATE VIEW v_cotizacion_actual AS
SELECT DISTINCT ON (empresa_id, moneda_codigo) empresa_id, moneda_codigo, compra, venta, usuario_registro, fecha
FROM cotizaciones
ORDER BY empresa_id, moneda_codigo, fecha DESC, id DESC;
ALTER VIEW v_cotizacion_actual SET (security_invoker = true);

-- ---------- 7. API de la casa de cambio (reemplazos con control de empresa) ----------
DROP FUNCTION IF EXISTS api_mi_perfil();
CREATE FUNCTION api_mi_perfil()
RETURNS TABLE (email TEXT, usuario TEXT, nombre TEXT, rol TEXT, empresa_id INT, empresa_nombre TEXT,
               plan TEXT, vence DATE, dias_restantes INT, estado TEXT,
               soporte_nombre TEXT, soporte_telefono TEXT, soporte_email TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; e empresas; a app_config;
BEGIN
    v := fn_perfil_base();
    SELECT * INTO a FROM app_config WHERE id = 1;
    IF v.rol <> 'DEV' THEN SELECT * INTO e FROM empresas WHERE id = v.empresa_id; END IF;
    RETURN QUERY SELECT v.email, replace(v.email, '@cmm.local', ''), v.nombre, v.rol::TEXT, v.empresa_id, e.nombre,
        e.plan::TEXT, e.vence, CASE WHEN e.plan = 'UNICO' OR e.vence IS NULL THEN NULL ELSE (e.vence - fn_hoy()) END,
        CASE WHEN v.rol = 'DEV' THEN 'OK' WHEN NOT e.activo THEN 'SUSPENDIDA'
             WHEN e.plan <> 'UNICO' AND e.vence < fn_hoy() THEN 'VENCIDA' ELSE 'OK' END,
        a.soporte_nombre, a.soporte_telefono, a.soporte_email;
END $$;

CREATE OR REPLACE FUNCTION api_crear_cliente(
    p_tipo TEXT, p_nombre TEXT, p_documento TEXT,
    p_telefono TEXT DEFAULT NULL, p_direccion TEXT DEFAULT NULL, p_observaciones TEXT DEFAULT NULL
) RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; v_id INT;
BEGIN
    v := fn_perfil_actual();
    IF coalesce(trim(p_nombre), '') = '' OR coalesce(trim(p_documento), '') = '' THEN
        RAISE EXCEPTION 'Nombre y documento son obligatorios';
    END IF;
    INSERT INTO clientes (empresa_id, tipo_persona, nombre_completo, documento, telefono, direccion, observaciones)
    VALUES (v.empresa_id, upper(p_tipo), trim(p_nombre), upper(trim(p_documento)),
            nullif(trim(p_telefono), ''), nullif(trim(p_direccion), ''), nullif(trim(p_observaciones), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Ya existe un cliente con documento %', p_documento;
END $$;

CREATE OR REPLACE FUNCTION api_actualizar_cliente(
    p_id INT, p_nombre TEXT, p_telefono TEXT, p_direccion TEXT, p_observaciones TEXT, p_activo BOOLEAN
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; v_act BOOLEAN;
BEGIN
    v := fn_perfil_actual();
    SELECT activo INTO v_act FROM clientes WHERE id = p_id AND empresa_id = v.empresa_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Cliente inexistente'; END IF;
    IF p_activo IS DISTINCT FROM v_act AND v.rol = 'CAJERO' THEN
        RAISE EXCEPTION 'Solo SUPERVISOR o ADMIN activa/desactiva clientes';
    END IF;
    IF coalesce(trim(p_nombre), '') = '' THEN RAISE EXCEPTION 'Nombre obligatorio'; END IF;
    UPDATE clientes SET nombre_completo = trim(p_nombre),
        telefono = nullif(trim(p_telefono), ''), direccion = nullif(trim(p_direccion), ''),
        observaciones = nullif(trim(p_observaciones), ''), activo = coalesce(p_activo, v_act)
    WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION api_operar_simple(
    p_cliente_id INT, p_moneda TEXT, p_tipo TEXT, p_monto NUMERIC, p_concepto TEXT,
    p_metodo TEXT DEFAULT 'EFECTIVO', p_comprobante TEXT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual();
    PERFORM fn_check_cliente(p_cliente_id, v.empresa_id);
    IF coalesce(trim(p_concepto), '') = '' THEN RAISE EXCEPTION 'Concepto obligatorio'; END IF;
    RETURN operar_simple(p_cliente_id, p_moneda, p_tipo, p_monto, v.email, trim(p_concepto),
                         p_metodo, nullif(trim(p_comprobante), ''));
END $$;

CREATE OR REPLACE FUNCTION api_operar_arbitraje(
    p_cliente_id INT, p_moneda_origen TEXT, p_moneda_destino TEXT, p_monto_origen NUMERIC,
    p_tasa NUMERIC, p_modo TEXT, p_concepto TEXT,
    p_pagar_efectivo BOOLEAN DEFAULT FALSE, p_permitir_negativo BOOLEAN DEFAULT FALSE,
    p_metodo TEXT DEFAULT 'EFECTIVO', p_comprobante TEXT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual();
    PERFORM fn_check_cliente(p_cliente_id, v.empresa_id);
    IF p_permitir_negativo AND v.rol = 'CAJERO' THEN
        RAISE EXCEPTION 'Solo SUPERVISOR o ADMIN autoriza cruces con saldo negativo';
    END IF;
    IF coalesce(trim(p_concepto), '') = '' THEN RAISE EXCEPTION 'Concepto obligatorio'; END IF;
    RETURN operar_arbitraje(p_cliente_id, p_moneda_origen, p_moneda_destino, p_monto_origen,
        p_tasa, p_modo, v.email, trim(p_concepto), p_pagar_efectivo, p_permitir_negativo,
        p_metodo, nullif(trim(p_comprobante), ''));
END $$;

CREATE OR REPLACE FUNCTION api_anular_operacion(p_operacion_id BIGINT, p_motivo TEXT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual(ARRAY['SUPERVISOR','ADMIN']);
    IF NOT EXISTS (SELECT 1 FROM operaciones WHERE id = p_operacion_id AND empresa_id = v.empresa_id) THEN
        RAISE EXCEPTION 'Operación inexistente';
    END IF;
    RETURN anular_operacion(p_operacion_id, v.email, p_motivo);
END $$;

CREATE OR REPLACE FUNCTION api_set_cotizacion(p_moneda TEXT, p_compra NUMERIC, p_venta NUMERIC)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; v_id BIGINT;
BEGIN
    v := fn_perfil_actual(ARRAY['SUPERVISOR','ADMIN']);
    IF p_venta < p_compra THEN RAISE EXCEPTION 'La venta no puede ser menor que la compra'; END IF;
    INSERT INTO cotizaciones (empresa_id, moneda_codigo, compra, venta, usuario_registro)
    VALUES (v.empresa_id, upper(p_moneda), p_compra, p_venta, v.email) RETURNING id INTO v_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION api_set_config(p_nombre TEXT, p_ruc TEXT, p_direccion TEXT, p_telefono TEXT, p_pie TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    IF coalesce(trim(p_nombre), '') = '' THEN RAISE EXCEPTION 'El nombre es obligatorio'; END IF;
    UPDATE empresas SET nombre = trim(p_nombre), ruc = nullif(trim(p_ruc), ''),
        direccion = nullif(trim(p_direccion), ''), telefono = nullif(trim(p_telefono), ''),
        pie_recibo = nullif(trim(p_pie), '')
    WHERE id = v.empresa_id;
END $$;

DROP FUNCTION IF EXISTS api_listar_usuarios();
CREATE FUNCTION api_listar_usuarios()
RETURNS TABLE (email TEXT, usuario TEXT, nombre TEXT, rol TEXT, activo BOOLEAN, ultimo_ingreso TIMESTAMPTZ, tiene_cuenta BOOLEAN, max_usuarios INT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    RETURN QUERY
    SELECT p.email, replace(p.email, '@cmm.local', ''), p.nombre, p.rol::TEXT, p.activo, u.last_sign_in_at, (u.id IS NOT NULL),
           (SELECT e.max_usuarios FROM empresas e WHERE e.id = v.empresa_id)
    FROM perfiles p LEFT JOIN auth.users u ON lower(u.email) = p.email
    WHERE p.empresa_id = v.empresa_id
    ORDER BY p.activo DESC, p.nombre;
END $$;

DROP FUNCTION IF EXISTS api_crear_usuario(TEXT, TEXT, TEXT, TEXT);
CREATE FUNCTION api_crear_usuario(p_usuario TEXT, p_nombre TEXT, p_rol TEXT, p_password TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; e TEXT; n INT; mx INT;
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    e := fn_email_de_usuario(p_usuario);
    IF coalesce(trim(p_nombre), '') = '' THEN RAISE EXCEPTION 'Nombre obligatorio'; END IF;
    IF upper(p_rol) NOT IN ('CAJERO','SUPERVISOR','ADMIN') THEN RAISE EXCEPTION 'Rol inválido'; END IF;
    IF EXISTS (SELECT 1 FROM perfiles WHERE email = e) THEN RAISE EXCEPTION 'Ese nombre de usuario ya está en uso'; END IF;
    SELECT count(*) INTO n FROM perfiles WHERE empresa_id = v.empresa_id AND activo;
    SELECT max_usuarios INTO mx FROM empresas WHERE id = v.empresa_id;
    IF n >= mx THEN RAISE EXCEPTION 'Su plan permite % usuarios activos. Contacte a su proveedor para ampliar.', mx; END IF;
    PERFORM fn_crear_cuenta(e, p_password, trim(p_nombre));
    INSERT INTO perfiles (email, nombre, rol, empresa_id) VALUES (e, trim(p_nombre), upper(p_rol), v.empresa_id);
END $$;

CREATE OR REPLACE FUNCTION api_actualizar_usuario(p_email TEXT, p_nombre TEXT, p_rol TEXT, p_activo BOOLEAN, p_password TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; e TEXT := lower(trim(p_email)); was BOOLEAN; n INT; mx INT;
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    SELECT activo INTO was FROM perfiles WHERE email = e AND empresa_id = v.empresa_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Usuario inexistente'; END IF;
    IF e = v.email AND (upper(p_rol) <> 'ADMIN' OR NOT p_activo) THEN
        RAISE EXCEPTION 'No puede quitarse a sí mismo el rol ADMIN ni desactivarse';
    END IF;
    IF upper(p_rol) NOT IN ('CAJERO','SUPERVISOR','ADMIN') THEN RAISE EXCEPTION 'Rol inválido'; END IF;
    IF p_activo AND NOT was THEN
        SELECT count(*) INTO n FROM perfiles WHERE empresa_id = v.empresa_id AND activo;
        SELECT max_usuarios INTO mx FROM empresas WHERE id = v.empresa_id;
        IF n >= mx THEN RAISE EXCEPTION 'Su plan permite % usuarios activos', mx; END IF;
    END IF;
    UPDATE perfiles SET nombre = trim(p_nombre), rol = upper(p_rol), activo = p_activo WHERE email = e;
    IF coalesce(p_password, '') <> '' THEN PERFORM fn_set_password(e, p_password); END IF;
END $$;

CREATE OR REPLACE FUNCTION api_cambiar_mi_password(p_password TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_base();
    PERFORM fn_set_password(v.email, p_password);
END $$;

-- ---------- 8. API del desarrollador ----------
CREATE OR REPLACE FUNCTION fn_nuevo_vence(p_actual DATE, p_plan TEXT, p_dias_prueba INT) RETURNS DATE
LANGUAGE sql STABLE AS $$
    SELECT CASE upper(p_plan)
        WHEN 'UNICO'   THEN NULL
        WHEN 'PRUEBA'  THEN fn_hoy() + p_dias_prueba
        WHEN 'MENSUAL' THEN (greatest(coalesce(p_actual, fn_hoy()), fn_hoy()) + INTERVAL '1 month')::date
        WHEN 'ANUAL'   THEN (greatest(coalesce(p_actual, fn_hoy()), fn_hoy()) + INTERVAL '1 year')::date
    END
$$;

CREATE OR REPLACE FUNCTION api_dev_empresas()
RETURNS TABLE (id INT, nombre TEXT, ruc TEXT, telefono TEXT, email_contacto TEXT, plan TEXT, vence DATE, activo BOOLEAN,
               max_usuarios INT, notas TEXT, creado TIMESTAMPTZ, estado TEXT, dias_restantes INT,
               usuarios INT, clientes INT, operaciones BIGINT, ultimo_pago TIMESTAMPTZ, admin_usuario TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM fn_dev();
    RETURN QUERY
    SELECT e.id, e.nombre, e.ruc, e.telefono, e.email_contacto, e.plan::TEXT, e.vence, e.activo, e.max_usuarios, e.notas, e.creado,
        CASE WHEN NOT e.activo THEN 'SUSPENDIDA' WHEN e.plan <> 'UNICO' AND e.vence < fn_hoy() THEN 'VENCIDA'
             WHEN e.plan <> 'UNICO' AND e.vence - fn_hoy() <= 7 THEN 'POR_VENCER' ELSE 'ACTIVA' END,
        CASE WHEN e.plan = 'UNICO' THEN NULL ELSE e.vence - fn_hoy() END,
        (SELECT count(*)::INT FROM perfiles p WHERE p.empresa_id = e.id AND p.activo),
        (SELECT count(*)::INT FROM clientes c WHERE c.empresa_id = e.id),
        (SELECT count(*) FROM operaciones o WHERE o.empresa_id = e.id),
        (SELECT max(pm.fecha) FROM pagos_membresia pm WHERE pm.empresa_id = e.id),
        (SELECT replace(p.email, '@cmm.local', '') FROM perfiles p WHERE p.empresa_id = e.id AND p.rol = 'ADMIN' ORDER BY p.email LIMIT 1)
    FROM empresas e ORDER BY e.nombre;
END $$;

CREATE OR REPLACE FUNCTION api_dev_crear_empresa(
    p_nombre TEXT, p_ruc TEXT, p_telefono TEXT, p_email TEXT, p_plan TEXT, p_max_usuarios INT,
    p_admin_usuario TEXT, p_admin_nombre TEXT, p_admin_password TEXT,
    p_monto NUMERIC DEFAULT 0, p_moneda TEXT DEFAULT 'USD', p_nota TEXT DEFAULT NULL
) RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d perfiles; a app_config; e_id INT; em TEXT; v_vence DATE;
BEGIN
    d := fn_dev();
    SELECT * INTO a FROM app_config WHERE id = 1;
    IF coalesce(trim(p_nombre), '') = '' THEN RAISE EXCEPTION 'Nombre de empresa obligatorio'; END IF;
    IF upper(p_plan) NOT IN ('PRUEBA','MENSUAL','ANUAL','UNICO') THEN RAISE EXCEPTION 'Plan inválido'; END IF;
    em := fn_email_de_usuario(p_admin_usuario);
    IF EXISTS (SELECT 1 FROM perfiles WHERE email = em) THEN RAISE EXCEPTION 'Ese nombre de usuario ya está en uso'; END IF;
    v_vence := fn_nuevo_vence(NULL, p_plan, a.dias_prueba);
    INSERT INTO empresas (nombre, ruc, telefono, email_contacto, plan, vence, max_usuarios, notas)
    VALUES (trim(p_nombre), nullif(trim(p_ruc), ''), nullif(trim(p_telefono), ''), nullif(trim(p_email), ''),
            upper(p_plan), v_vence, coalesce(p_max_usuarios, 3), nullif(trim(p_nota), ''))
    RETURNING id INTO e_id;
    PERFORM fn_crear_cuenta(em, p_admin_password, coalesce(nullif(trim(p_admin_nombre), ''), 'Administrador'));
    INSERT INTO perfiles (email, nombre, rol, empresa_id) VALUES (em, coalesce(nullif(trim(p_admin_nombre), ''), 'Administrador'), 'ADMIN', e_id);
    INSERT INTO pagos_membresia (empresa_id, plan, monto, moneda, vence_anterior, vence_nuevo, nota, usuario_registro)
    VALUES (e_id, upper(p_plan), coalesce(p_monto, 0), upper(coalesce(p_moneda, 'USD')), NULL, v_vence,
            coalesce(nullif(trim(p_nota), ''), 'Alta de empresa'), d.email);
    RETURN e_id;
END $$;

CREATE OR REPLACE FUNCTION api_dev_registrar_pago(p_empresa INT, p_plan TEXT, p_monto NUMERIC, p_moneda TEXT, p_nota TEXT DEFAULT NULL)
RETURNS DATE LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d perfiles; a app_config; e empresas; v_nuevo DATE;
BEGIN
    d := fn_dev();
    SELECT * INTO a FROM app_config WHERE id = 1;
    SELECT * INTO e FROM empresas WHERE id = p_empresa FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Empresa inexistente'; END IF;
    IF upper(p_plan) NOT IN ('MENSUAL','ANUAL','UNICO') THEN RAISE EXCEPTION 'Plan inválido para un pago'; END IF;
    IF coalesce(p_monto, -1) < 0 THEN RAISE EXCEPTION 'Monto inválido'; END IF;
    v_nuevo := fn_nuevo_vence(CASE WHEN e.plan = 'UNICO' THEN NULL ELSE e.vence END, p_plan, a.dias_prueba);
    UPDATE empresas SET plan = upper(p_plan), vence = v_nuevo, activo = TRUE WHERE id = p_empresa;
    INSERT INTO pagos_membresia (empresa_id, plan, monto, moneda, vence_anterior, vence_nuevo, nota, usuario_registro)
    VALUES (p_empresa, upper(p_plan), p_monto, upper(coalesce(p_moneda, 'USD')), e.vence, v_nuevo, nullif(trim(p_nota), ''), d.email);
    RETURN v_nuevo;
END $$;

CREATE OR REPLACE FUNCTION api_dev_actualizar_empresa(
    p_id INT, p_nombre TEXT, p_ruc TEXT, p_telefono TEXT, p_email TEXT, p_activo BOOLEAN,
    p_max_usuarios INT, p_vence DATE, p_notas TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e empresas;
BEGIN
    PERFORM fn_dev();
    SELECT * INTO e FROM empresas WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Empresa inexistente'; END IF;
    IF coalesce(trim(p_nombre), '') = '' THEN RAISE EXCEPTION 'Nombre obligatorio'; END IF;
    IF e.plan <> 'UNICO' AND p_vence IS NULL THEN RAISE EXCEPTION 'Indique la fecha de vencimiento'; END IF;
    UPDATE empresas SET nombre = trim(p_nombre), ruc = nullif(trim(p_ruc), ''), telefono = nullif(trim(p_telefono), ''),
        email_contacto = nullif(trim(p_email), ''), activo = p_activo, max_usuarios = coalesce(p_max_usuarios, max_usuarios),
        vence = CASE WHEN plan = 'UNICO' THEN NULL ELSE p_vence END, notas = nullif(trim(p_notas), '')
    WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION api_dev_pagos(p_empresa INT DEFAULT NULL)
RETURNS TABLE (id BIGINT, empresa_id INT, empresa TEXT, plan TEXT, monto NUMERIC, moneda TEXT,
               vence_anterior DATE, vence_nuevo DATE, nota TEXT, usuario_registro TEXT, fecha TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM fn_dev();
    RETURN QUERY
    SELECT pm.id, pm.empresa_id, e.nombre, pm.plan::TEXT, pm.monto, pm.moneda::TEXT, pm.vence_anterior, pm.vence_nuevo,
           pm.nota, pm.usuario_registro, pm.fecha
    FROM pagos_membresia pm JOIN empresas e ON e.id = pm.empresa_id
    WHERE p_empresa IS NULL OR pm.empresa_id = p_empresa
    ORDER BY pm.id DESC LIMIT 1000;
END $$;

CREATE OR REPLACE FUNCTION api_dev_usuarios(p_empresa INT)
RETURNS TABLE (email TEXT, usuario TEXT, nombre TEXT, rol TEXT, activo BOOLEAN, ultimo_ingreso TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM fn_dev();
    RETURN QUERY
    SELECT p.email, replace(p.email, '@cmm.local', ''), p.nombre, p.rol::TEXT, p.activo, u.last_sign_in_at
    FROM perfiles p LEFT JOIN auth.users u ON lower(u.email) = p.email
    WHERE p.empresa_id = p_empresa ORDER BY p.rol, p.nombre;
END $$;

CREATE OR REPLACE FUNCTION api_dev_crear_usuario(p_empresa INT, p_usuario TEXT, p_nombre TEXT, p_rol TEXT, p_password TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e TEXT;
BEGIN
    PERFORM fn_dev();
    IF NOT EXISTS (SELECT 1 FROM empresas WHERE id = p_empresa) THEN RAISE EXCEPTION 'Empresa inexistente'; END IF;
    e := fn_email_de_usuario(p_usuario);
    IF upper(p_rol) NOT IN ('CAJERO','SUPERVISOR','ADMIN') THEN RAISE EXCEPTION 'Rol inválido'; END IF;
    IF EXISTS (SELECT 1 FROM perfiles WHERE email = e) THEN RAISE EXCEPTION 'Ese nombre de usuario ya está en uso'; END IF;
    PERFORM fn_crear_cuenta(e, p_password, trim(p_nombre));
    INSERT INTO perfiles (email, nombre, rol, empresa_id) VALUES (e, coalesce(nullif(trim(p_nombre), ''), p_usuario), upper(p_rol), p_empresa);
END $$;

CREATE OR REPLACE FUNCTION api_dev_actualizar_usuario(p_email TEXT, p_rol TEXT, p_activo BOOLEAN, p_password TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e TEXT := lower(trim(p_email));
BEGIN
    PERFORM fn_dev();
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE email = e AND rol <> 'DEV') THEN RAISE EXCEPTION 'Usuario inexistente'; END IF;
    IF upper(p_rol) NOT IN ('CAJERO','SUPERVISOR','ADMIN') THEN RAISE EXCEPTION 'Rol inválido'; END IF;
    UPDATE perfiles SET rol = upper(p_rol), activo = p_activo WHERE email = e;
    IF coalesce(p_password, '') <> '' THEN PERFORM fn_set_password(e, p_password); END IF;
END $$;

CREATE OR REPLACE FUNCTION api_dev_config()
RETURNS SETOF app_config LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM fn_dev();
    RETURN QUERY SELECT * FROM app_config WHERE id = 1;
END $$;

CREATE OR REPLACE FUNCTION api_dev_set_config(
    p_soporte_nombre TEXT, p_soporte_telefono TEXT, p_soporte_email TEXT, p_moneda TEXT,
    p_mensual NUMERIC, p_anual NUMERIC, p_unico NUMERIC, p_dias_prueba INT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    PERFORM fn_dev();
    UPDATE app_config SET soporte_nombre = nullif(trim(p_soporte_nombre), ''), soporte_telefono = nullif(trim(p_soporte_telefono), ''),
        soporte_email = nullif(trim(p_soporte_email), ''), moneda_precios = upper(coalesce(p_moneda, 'USD')),
        precio_mensual = coalesce(p_mensual, 0), precio_anual = coalesce(p_anual, 0), precio_unico = coalesce(p_unico, 0),
        dias_prueba = coalesce(p_dias_prueba, 7)
    WHERE id = 1;
END $$;

-- ---------- 9. RLS por empresa ----------
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['clientes','cartera_cliente','operaciones','movimientos_cartera','cotizaciones'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS lectura_usuarios ON %I', t);
        EXECUTE format('DROP POLICY IF EXISTS lectura_empresa ON %I', t);
        EXECUTE format('CREATE POLICY lectura_empresa ON %I FOR SELECT TO authenticated USING (empresa_id = fn_empresa_actual() AND fn_empresa_vigente(empresa_id))', t);
    END LOOP;
END $$;

ALTER TABLE monedas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lectura_usuarios ON monedas;
CREATE POLICY lectura_usuarios ON monedas FOR SELECT TO authenticated USING (fn_es_usuario());

ALTER TABLE perfiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lectura_usuarios ON perfiles;
DROP POLICY IF EXISTS lectura_propia ON perfiles;
CREATE POLICY lectura_propia ON perfiles FOR SELECT TO authenticated USING (email = lower(auth.jwt() ->> 'email'));

ALTER TABLE empresas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lectura_propia ON empresas;
CREATE POLICY lectura_propia ON empresas FOR SELECT TO authenticated USING (id = fn_empresa_actual());

ALTER TABLE pagos_membresia ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

-- ---------- 10. Permisos ----------
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

GRANT SELECT ON monedas, clientes, cartera_cliente, operaciones, movimientos_cartera, perfiles, empresas, cotizaciones,
    v_ficha_cartera, v_extracto, v_auditoria_descuadres, v_resumen_dia, v_posicion_monedas,
    v_cotizacion_actual, v_operaciones
    TO authenticated;

GRANT EXECUTE ON FUNCTION fn_signo(TEXT), fn_es_usuario(), fn_empresa_actual(), fn_empresa_vigente(INT),
    api_mi_perfil(), api_cambiar_mi_password(TEXT),
    api_crear_cliente(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT),
    api_actualizar_cliente(INT, TEXT, TEXT, TEXT, TEXT, BOOLEAN),
    api_operar_simple(INT, TEXT, TEXT, NUMERIC, TEXT, TEXT, TEXT),
    api_operar_arbitraje(INT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT),
    api_anular_operacion(BIGINT, TEXT),
    api_set_cotizacion(TEXT, NUMERIC, NUMERIC),
    api_set_config(TEXT, TEXT, TEXT, TEXT, TEXT),
    api_listar_usuarios(), api_crear_usuario(TEXT, TEXT, TEXT, TEXT),
    api_actualizar_usuario(TEXT, TEXT, TEXT, BOOLEAN, TEXT),
    api_dev_empresas(),
    api_dev_crear_empresa(TEXT, TEXT, TEXT, TEXT, TEXT, INT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT),
    api_dev_registrar_pago(INT, TEXT, NUMERIC, TEXT, TEXT),
    api_dev_actualizar_empresa(INT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INT, DATE, TEXT),
    api_dev_pagos(INT), api_dev_usuarios(INT),
    api_dev_crear_usuario(INT, TEXT, TEXT, TEXT, TEXT),
    api_dev_actualizar_usuario(TEXT, TEXT, BOOLEAN, TEXT),
    api_dev_config(), api_dev_set_config(TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, INT)
    TO authenticated;
