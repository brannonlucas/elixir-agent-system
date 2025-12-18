defmodule NervousSystemWeb.PageControllerTest do
  use NervousSystemWeb.ConnCase

  test "GET / renders landing page", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Nervous System"
    assert response =~ "Multi-Agent Deliberation Engine"
  end

  test "GET / shows all agent personalities", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    # Verify agent personalities are displayed
    assert response =~ "Analyst"
    assert response =~ "Advocate"
    assert response =~ "Skeptic"
    assert response =~ "Historian"
    assert response =~ "Futurist"
    assert response =~ "Pragmatist"
    assert response =~ "Ethicist"
  end
end
