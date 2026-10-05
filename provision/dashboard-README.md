# Wall-panel dashboard for the TSW-760 and TSW-1060

`dashboard-tsw1060.yaml` is an example Home Assistant dashboard for the kiosk. Replace the example entity ids (marked `# example`) with your own.

## Install the dashboard

1. In Home Assistant, open Settings -> Dashboards -> Add dashboard.
2. Choose "from scratch" and set the URL to `wall-panel`.
3. In the dashboard, open Edit -> Raw configuration editor and paste the YAML.
4. On the panel, run `tsx-config set KIOSK_URL https://ha.example.org/wall-panel/home` and `tsx-config apply`. The *Kiosk URL* entity in Home Assistant does the same.
5. On the panel, run `rc-service kiosk restart`.

## Dashboard design for the panel

The panel has a 4-core 1.6 GHz Cortex-A9. With the browser GPU patch, the Mali-450 does the compositing. The CPU always runs the JavaScript, style and layout work of the page. These items cost the most:

| Costly on the panel | Use instead |
|---|---|
| history-graph, statistics-graph, `trend-graph` feature, mini-graph and apexcharts cards (they run recorder queries and redraw the chart on every update) | A tile card with the current value. Show graphs on a phone or PC |
| Camera cards (the CPU decodes live video) | A snapshot that shows only on a tap (more-info), or nothing |
| Map cards (tiles, markers, animated zoom) | A person badge |
| Animated backgrounds, weather animations, card-mod animations | Static colors. The kiosk already asks pages for reduced motion |
| One very long view | Several short views (tabs at the top) that each fit 1280x800 |
| Masonry view, deep vertical or horizontal stacks | Sections view with tile cards and `grid_options` |

## Reference

| Item | Value |
|---|---|
| Page size | 1280x800 |
| Page size with the on-screen keyboard open | 1280x534. Text fields (for example in more-info dialogs) stay visible above the keyboard |
| `max_columns` | `3` fits the 1280 px width when the sidebar is hidden. Sections reflow at about 1050 px content width |
| Panel user | Use a dedicated non-admin HA user (token: `kiosk-set-token`). A tap then cannot reach the settings |
| Front keys | The front keys have no action by default. To switch views, bind the `tsx-buttons` action `navigate /wall-panel/media` to a key, for example `on lights long navigate /wall-panel/media` in `/etc/tsx/buttons.conf` |

### Hide the sidebar and the header

Use one of these methods:

- Without an add-on: on the profile page of the HA user, turn on "Always hide the sidebar". The kiosk browser profile stores this setting. Set it once through the DevTools tunnel.
- With the HACS plugin **kiosk-mode**: put `kiosk_mode: {hide_header: true, hide_sidebar: true}` at the top of the YAML. Add `?disable_km` to the URL to show the header again for editing.
