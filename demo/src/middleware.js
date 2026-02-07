/**
 * Authentication middleware.
 *
 * Expects an "Authorization" header with value "Bearer <token>".
 * Any non-empty bearer token is accepted for this demo.
 *
 * BUG: Returns 403 Forbidden instead of 401 Unauthorized
 *       when the Authorization header is missing or malformed.
 *       RFC 7235 specifies 401 for missing/invalid credentials.
 */
function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;

  if (!authHeader) {
    // BUG: Should be 401, not 403
    return res.status(403).json({ error: 'Authorization header required' });
  }

  const parts = authHeader.split(' ');
  if (parts.length !== 2 || parts[0] !== 'Bearer') {
    // BUG: Should be 401, not 403
    return res.status(403).json({ error: 'Invalid authorization format. Use: Bearer <token>' });
  }

  const token = parts[1];
  if (!token || token.trim() === '') {
    // BUG: Should be 401, not 403
    return res.status(403).json({ error: 'Token required' });
  }

  // In a real app, we'd verify the token here
  req.userId = 'demo-user';
  next();
}

module.exports = { authMiddleware };
