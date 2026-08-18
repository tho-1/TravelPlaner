import streamlit as st


def render_info():
    st.title("ℹ️ How to use")
    st.caption("Quick guide to the Travel Planner")

    st.markdown(
        """
        ### Navigation

        - **Overview** — Browse all destinations, filter by continent, EU membership,
          safety rating, or whether a destination is in your closer selection.
        - **Destination tabs** — Click any destination button on the Overview page
          to open it as its own tab in the sidebar. Each tab shows detailed
          information about that destination.
        - **⭐ Show favorites** — Opens a tab for every destination marked with an
          **x** in the *In näherer Auswahl?* column.

        ### Closing tabs

        Each destination detail page has a **✖ Close tab** button at the top.
        Clicking it removes the tab from the sidebar and returns you to the Overview.

        ### Filtering

        Use the filter widgets on the Overview page to narrow down destinations:

        | Filter | Description |
        |--------|-------------|
        | **Continent** | Show only destinations on a specific continent. |
        | **Country** | Show only destinations in a specific country. |
        | **EU?** | Filter by EU / non-EU membership. |
        | **In näherer Auswahl?** | Show only destinations in your closer selection. |
        | **Safety rating** | Restrict to a safety-rating range. |
        """
    )
