-- =====================================================================
-- CARTERA MULTIMONEDA — MIGRACIÓN v6: contraseña temporal + mínimo 6 caracteres
-- * Todo usuario nuevo o con contraseña reseteada debe cambiarla al ingresar
-- * Largo mínimo de contraseña: 6
-- Ejecutar UNA vez después de migracion_v5.sql
-- =====================================================================

-- Usuarios nuevos nacen con contraseña temporal; los existentes no
ALTER TABLE perfiles ADD COLUMN IF NOT EXISTS debe_cambiar_clave BOOLEAN;
UPDATE perfiles SET debe_cambiar_clave = FALSE WHERE debe_cambiar_clave IS NULL;
ALTER TABLE perfiles ALTER COLUMN debe_cambiar_clave SET DEFAULT TRUE;
ALTER TABLE perfiles ALTER COLUMN debe_cambiar_clave SET NOT NULL;

-- Cuenta de acceso: mínimo 6
CREATE OR REPLACE FUNCTION fn_crear_cuenta(p_email TEXT, p_password TEXT, p_nombre TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID;
BEGIN
    SELECT id INTO uid FROM auth.users WHERE lower(email) = p_email;
    IF uid IS NOT NULL THEN
        IF coalesce(p_password, '') <> '' THEN
            IF length(p_password) < 6 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 6 caracteres'; END IF;
            UPDATE auth.users SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() WHERE id = uid;
        END IF;
        RETURN uid;
    END IF;
    IF length(coalesce(p_password, '')) < 6 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 6 caracteres'; END IF;
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

-- Reseteo hecho por ADMIN o DEV: queda como temporal
CREATE OR REPLACE FUNCTION fn_set_password(p_email TEXT, p_password TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF length(coalesce(p_password, '')) < 6 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 6 caracteres'; END IF;
    UPDATE auth.users SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
    WHERE lower(email) = p_email;
    IF NOT FOUND THEN RAISE EXCEPTION 'La cuenta de acceso no existe'; END IF;
    UPDATE perfiles SET debe_cambiar_clave = TRUE WHERE email = p_email;
END $$;

-- Cambio hecho por el propio usuario: deja de ser temporal
CREATE OR REPLACE FUNCTION api_cambiar_mi_password(p_password TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; actual TEXT;
BEGIN
    v := fn_perfil_base();
    IF length(coalesce(p_password, '')) < 6 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 6 caracteres'; END IF;
    SELECT encrypted_password INTO actual FROM auth.users WHERE lower(email) = v.email;
    IF actual IS NOT NULL AND extensions.crypt(p_password, actual) = actual THEN
        RAISE EXCEPTION 'La nueva contraseña debe ser distinta de la actual';
    END IF;
    UPDATE auth.users SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
    WHERE lower(email) = v.email;
    UPDATE perfiles SET debe_cambiar_clave = FALSE WHERE email = v.email;
END $$;

-- Perfil con la marca de contraseña temporal
DROP FUNCTION IF EXISTS api_mi_perfil();
CREATE FUNCTION api_mi_perfil()
RETURNS TABLE (email TEXT, usuario TEXT, nombre TEXT, rol TEXT, empresa_id INT, empresa_nombre TEXT,
               plan TEXT, vence DATE, dias_restantes INT, estado TEXT,
               soporte_nombre TEXT, soporte_telefono TEXT, soporte_email TEXT, debe_cambiar_clave BOOLEAN)
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
        a.soporte_nombre, a.soporte_telefono, a.soporte_email, v.debe_cambiar_clave;
END $$;

-- Mientras la contraseña sea temporal no puede operar
CREATE OR REPLACE FUNCTION fn_perfil_actual(p_roles TEXT[] DEFAULT NULL) RETURNS perfiles
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_base();
    IF v.rol = 'DEV' THEN RAISE EXCEPTION 'Acción no disponible desde el panel de desarrollador'; END IF;
    IF v.debe_cambiar_clave THEN RAISE EXCEPTION 'Debe cambiar su contraseña temporal antes de continuar'; END IF;
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
    IF v.debe_cambiar_clave THEN RAISE EXCEPTION 'Debe cambiar su contraseña temporal antes de continuar'; END IF;
    RETURN v;
END $$;

-- Sin acceso a datos mientras la contraseña sea temporal
CREATE OR REPLACE FUNCTION fn_empresa_actual() RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT empresa_id FROM perfiles WHERE email = lower(auth.jwt() ->> 'email') AND activo AND NOT debe_cambiar_clave
$$;

REVOKE EXECUTE ON FUNCTION api_mi_perfil(), api_cambiar_mi_password(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api_mi_perfil(), api_cambiar_mi_password(TEXT) TO authenticated;
