// Valida los datos firmados que Telegram le pasa al juego al abrirlo (initData).
// Método HMAC con el token del bot: el token vive como secreto del Worker (BOT_TOKEN),
// nunca en el repo ni en un documento.

const enc = new TextEncoder();

async function hmac(keyBytes, msg) {
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(msg)));
}

const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");

function sameText(a, b) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// Devuelve {user, authDate, startParam, chatType, chatInstance} o null si la firma no da
// o los datos son más viejos que maxAgeS.
export async function verifyInitData(initData, botToken, nowMs, maxAgeS = 86400) {
  if (!initData || !botToken) return null;
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) return null;
  const pairs = [];
  for (const [k, v] of params) if (k !== "hash") pairs.push(`${k}=${v}`);
  pairs.sort();
  const secret = await hmac(enc.encode("WebAppData"), botToken);
  const check = hex(await hmac(secret, pairs.join("\n")));
  if (!sameText(check, hash.toLowerCase())) return null;
  const authDate = Number(params.get("auth_date"));
  if (!Number.isFinite(authDate) || nowMs / 1000 - authDate > maxAgeS) return null;
  let user = null;
  try {
    user = JSON.parse(params.get("user") || "null");
  } catch {
    return null;
  }
  if (!user || !Number.isInteger(user.id)) return null;
  return {
    user,
    authDate,
    startParam: params.get("start_param") || "",
    chatType: params.get("chat_type") || "",
    chatInstance: params.get("chat_instance") || "",
  };
}

// Para las pruebas: firma datos como lo haría Telegram.
export async function signInitData(fields, botToken) {
  const pairs = Object.entries(fields).map(([k, v]) => `${k}=${v}`);
  pairs.sort();
  const secret = await hmac(enc.encode("WebAppData"), botToken);
  const hash = hex(await hmac(secret, pairs.join("\n")));
  const p = new URLSearchParams(fields);
  p.set("hash", hash);
  return p.toString();
}

// Nombre falso y estable de un jugador para las planillas: nadie puede volver al número
// de Telegram sin el secreto del servidor, pero el mismo jugador sale siempre igual.
export async function pseudonym(secret, userId) {
  return hex(await hmac(enc.encode(secret), `sum32:player:${userId}`)).slice(0, 12);
}

// Semilla del Daily: sale de un secreto del servidor, así nadie puede calcular la grilla
// de mañana antes de tiempo.
export async function dailySeed(secret, day) {
  const h = await hmac(enc.encode(secret), `sum32:daily:${day}`);
  return ((h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3]) >>> 0;
}
