export async function POST(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }

  const { code } = await request.json();
  if (!code) {
    return Response.json({ error: "Missing code" }, { status: 400 });
  }

  const clientId = process.env.GITHUB_CLIENT_ID;
  const clientSecret = process.env.GITHUB_CLIENT_SECRET;

  if (!clientId || !clientSecret) {
    return Response.json({ error: "Server misconfigured" }, { status: 500 });
  }

  const tokenResponse = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      client_id: clientId,
      client_secret: clientSecret,
      code,
    }),
  });

  const data = await tokenResponse.json();

  if (data.error) {
    return Response.json({ error: data.error_description || data.error }, { status: 400 });
  }

  return Response.json({ access_token: data.access_token });
}
