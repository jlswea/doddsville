//! Doddsville TUI - Rust/Ratatui Prototype
//!
//! A terminal user interface for managing stock transactions.
//! Build with: cargo build --release
//! Run with: cargo run or ./target/release/dv

use anyhow::Result;
use chrono::NaiveDate;
use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style, Stylize},
    text::{Line, Span},
    widgets::{
        Block, Borders, Cell, Clear, Paragraph, Row, Table, TableState, Wrap,
    },
    Frame, Terminal,
};
use rusqlite::Connection;
use std::io;

#[derive(Debug, Clone)]
struct Transaction {
    id: i64,
    date: String,
    tx_type: String,
    company: String,
    quantity: i64,
    unit_value: i64,  // cents
    total_value: i64, // cents
    cost: i64,        // cents
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum InputMode {
    Normal,
    Adding,
    Search,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum TransactionType {
    Buy,
    Sell,
    Dividend,
}

impl TransactionType {
    fn as_str(&self) -> &'static str {
        match self {
            TransactionType::Buy => "buy",
            TransactionType::Sell => "sell",
            TransactionType::Dividend => "dividend",
        }
    }
}

struct App {
    transactions: Vec<Transaction>,
    table_state: TableState,
    input_mode: InputMode,
    search_input: String,
    db_path: String,
    message: Option<String>,
    adding_type: Option<TransactionType>,
}

impl App {
    fn new(db_path: &str) -> Self {
        let mut app = Self {
            transactions: Vec::new(),
            table_state: TableState::default(),
            input_mode: InputMode::Normal,
            search_input: String::new(),
            db_path: db_path.to_string(),
            message: None,
            adding_type: None,
        };
        app.load_transactions();
        if !app.transactions.is_empty() {
            app.table_state.select(Some(0));
        }
        app
    }

    fn load_transactions(&mut self) {
        self.transactions.clear();

        let conn = match Connection::open(&self.db_path) {
            Ok(c) => c,
            Err(e) => {
                self.message = Some(format!("DB Error: {}", e));
                return;
            }
        };

        // Try new schema first, fall back to trans table
        let query = r#"
            SELECT
                t.id,
                t.date,
                t.type,
                COALESCE(c.name, '-'),
                COALESCE(t.quantity, 0),
                COALESCE(t.unit_value, 0),
                COALESCE(t.total_value, 0),
                COALESCE(t.cost, 0)
            FROM "transaction" t
            LEFT JOIN company c ON t.company = c.id
            ORDER BY t.date DESC
            LIMIT 100
        "#;

        let fallback_query = r#"
            SELECT
                id,
                date,
                type,
                com,
                amount,
                price,
                (amount * price),
                cost
            FROM trans
            ORDER BY date DESC
            LIMIT 100
        "#;

        let result = conn.prepare(query).and_then(|mut stmt| {
            stmt.query_map([], |row| {
                Ok(Transaction {
                    id: row.get(0)?,
                    date: row.get(1)?,
                    tx_type: row.get(2)?,
                    company: row.get(3)?,
                    quantity: row.get(4)?,
                    unit_value: row.get(5)?,
                    total_value: row.get(6)?,
                    cost: row.get(7)?,
                })
            })
            .map(|rows| rows.filter_map(|r| r.ok()).collect::<Vec<_>>())
        });

        match result {
            Ok(txs) => self.transactions = txs,
            Err(_) => {
                // Try fallback
                if let Ok(mut stmt) = conn.prepare(fallback_query) {
                    if let Ok(rows) = stmt.query_map([], |row| {
                        Ok(Transaction {
                            id: row.get(0)?,
                            date: row.get(1)?,
                            tx_type: row.get(2)?,
                            company: row.get(3)?,
                            quantity: row.get(4)?,
                            unit_value: row.get(5)?,
                            total_value: row.get(6)?,
                            cost: row.get(7)?,
                        })
                    }) {
                        self.transactions = rows.filter_map(|r| r.ok()).collect();
                    }
                }
            }
        }
    }

    fn next_row(&mut self) {
        if self.transactions.is_empty() {
            return;
        }
        let i = match self.table_state.selected() {
            Some(i) => {
                if i >= self.transactions.len() - 1 {
                    0
                } else {
                    i + 1
                }
            }
            None => 0,
        };
        self.table_state.select(Some(i));
    }

    fn previous_row(&mut self) {
        if self.transactions.is_empty() {
            return;
        }
        let i = match self.table_state.selected() {
            Some(i) => {
                if i == 0 {
                    self.transactions.len() - 1
                } else {
                    i - 1
                }
            }
            None => 0,
        };
        self.table_state.select(Some(i));
    }

    fn format_cents(cents: i64) -> String {
        if cents == 0 {
            "-".to_string()
        } else {
            format!("{:.2}", cents as f64 / 100.0)
        }
    }

    fn type_color(tx_type: &str) -> Color {
        match tx_type {
            "buy" => Color::Green,
            "sell" => Color::Red,
            "dividend" => Color::Cyan,
            "interest" => Color::Yellow,
            "deposit" => Color::Blue,
            "withdrawal" => Color::Magenta,
            "transfer" => Color::White,
            _ => Color::Gray,
        }
    }
}

fn main() -> Result<()> {
    // Setup terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Create app
    let mut app = App::new("data.db");

    // Main loop
    let res = run_app(&mut terminal, &mut app);

    // Restore terminal
    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture
    )?;
    terminal.show_cursor()?;

    if let Err(err) = res {
        println!("Error: {:?}", err);
    }

    Ok(())
}

fn run_app<B: ratatui::backend::Backend>(terminal: &mut Terminal<B>, app: &mut App) -> Result<()> {
    loop {
        terminal.draw(|f| ui(f, app))?;

        if let Event::Key(key) = event::read()? {
            if key.kind != KeyEventKind::Press {
                continue;
            }

            match app.input_mode {
                InputMode::Normal => match key.code {
                    KeyCode::Char('q') => return Ok(()),
                    KeyCode::Char('j') | KeyCode::Down => app.next_row(),
                    KeyCode::Char('k') | KeyCode::Up => app.previous_row(),
                    KeyCode::Char('b') => {
                        app.adding_type = Some(TransactionType::Buy);
                        app.input_mode = InputMode::Adding;
                        app.message = Some("Adding BUY transaction... (ESC to cancel)".into());
                    }
                    KeyCode::Char('s') => {
                        app.adding_type = Some(TransactionType::Sell);
                        app.input_mode = InputMode::Adding;
                        app.message = Some("Adding SELL transaction... (ESC to cancel)".into());
                    }
                    KeyCode::Char('d') => {
                        app.adding_type = Some(TransactionType::Dividend);
                        app.input_mode = InputMode::Adding;
                        app.message = Some("Adding DIVIDEND... (ESC to cancel)".into());
                    }
                    KeyCode::Char('/') => {
                        app.input_mode = InputMode::Search;
                        app.search_input.clear();
                    }
                    KeyCode::Char('r') => {
                        app.load_transactions();
                        app.message = Some("Refreshed".into());
                    }
                    _ => {}
                },
                InputMode::Adding => match key.code {
                    KeyCode::Esc => {
                        app.input_mode = InputMode::Normal;
                        app.adding_type = None;
                        app.message = None;
                    }
                    KeyCode::Enter => {
                        // In a full implementation, you'd collect form data here
                        app.message = Some(format!(
                            "Would add {} transaction (form not implemented in prototype)",
                            app.adding_type.map(|t| t.as_str()).unwrap_or("?")
                        ));
                        app.input_mode = InputMode::Normal;
                        app.adding_type = None;
                    }
                    _ => {}
                },
                InputMode::Search => match key.code {
                    KeyCode::Esc => {
                        app.input_mode = InputMode::Normal;
                        app.search_input.clear();
                    }
                    KeyCode::Enter => {
                        app.message = Some(format!("Searched for: {}", app.search_input));
                        app.input_mode = InputMode::Normal;
                    }
                    KeyCode::Backspace => {
                        app.search_input.pop();
                    }
                    KeyCode::Char(c) => {
                        app.search_input.push(c);
                    }
                    _ => {}
                },
            }
        }
    }
}

fn ui(f: &mut Frame, app: &App) {
    let size = f.area();

    // Main layout: header, content, footer
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3), // Header
            Constraint::Min(0),    // Content
            Constraint::Length(3), // Footer
        ])
        .split(size);

    // Header
    let header = Paragraph::new(vec![
        Line::from(vec![
            Span::styled("Doddsville", Style::default().fg(Color::Cyan).bold()),
            Span::raw(" - Stock Portfolio Manager"),
        ]),
    ])
    .block(Block::default().borders(Borders::ALL).border_style(Style::default().fg(Color::Cyan)));
    f.render_widget(header, chunks[0]);

    // Content: sidebar + table
    let content_chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(28), Constraint::Min(0)])
        .split(chunks[1]);

    // Sidebar
    let sidebar_text = vec![
        Line::from(Span::styled("Portfolio Summary", Style::default().bold().fg(Color::Cyan))),
        Line::from(""),
        Line::from(vec![
            Span::raw("Positions: "),
            Span::styled(
                format!("{}", app.transactions.iter().filter(|t| t.tx_type == "buy").count()),
                Style::default().fg(Color::Green),
            ),
        ]),
        Line::from(vec![
            Span::raw("Transactions: "),
            Span::styled(format!("{}", app.transactions.len()), Style::default().fg(Color::Yellow)),
        ]),
    ];
    let sidebar = Paragraph::new(sidebar_text)
        .block(Block::default().borders(Borders::ALL).title("Summary"))
        .wrap(Wrap { trim: true });
    f.render_widget(sidebar, content_chunks[0]);

    // Transaction table
    let header_cells = ["ID", "Date", "Type", "Stock", "Qty", "Price", "Total", "Fees"]
        .iter()
        .map(|h| Cell::from(*h).style(Style::default().fg(Color::Yellow).bold()));
    let header_row = Row::new(header_cells).height(1);

    let rows = app.transactions.iter().map(|tx| {
        let type_style = Style::default().fg(App::type_color(&tx.tx_type));
        Row::new(vec![
            Cell::from(tx.id.to_string()),
            Cell::from(tx.date.clone()),
            Cell::from(tx.tx_type.to_uppercase()).style(type_style),
            Cell::from(if tx.company.len() > 18 {
                format!("{}...", &tx.company[..18])
            } else {
                tx.company.clone()
            }),
            Cell::from(tx.quantity.to_string()),
            Cell::from(App::format_cents(tx.unit_value)),
            Cell::from(App::format_cents(tx.total_value)),
            Cell::from(App::format_cents(tx.cost)),
        ])
    });

    let table = Table::new(
        rows,
        [
            Constraint::Length(5),  // ID
            Constraint::Length(12), // Date
            Constraint::Length(8),  // Type
            Constraint::Min(20),    // Stock
            Constraint::Length(6),  // Qty
            Constraint::Length(10), // Price
            Constraint::Length(12), // Total
            Constraint::Length(8),  // Fees
        ],
    )
    .header(header_row)
    .block(Block::default().borders(Borders::ALL).title("Transactions"))
    .row_highlight_style(Style::default().add_modifier(Modifier::REVERSED).fg(Color::Cyan));

    f.render_stateful_widget(table, content_chunks[1], &mut app.table_state.clone());

    // Footer with keybindings
    let mode_text = match app.input_mode {
        InputMode::Normal => "NORMAL",
        InputMode::Adding => "ADDING",
        InputMode::Search => "SEARCH",
    };

    let footer_spans = vec![
        Span::styled(format!(" {} ", mode_text), Style::default().bg(Color::Cyan).fg(Color::Black).bold()),
        Span::raw("  "),
        Span::styled("q", Style::default().fg(Color::Yellow)),
        Span::raw(" Quit  "),
        Span::styled("b", Style::default().fg(Color::Yellow)),
        Span::raw(" Buy  "),
        Span::styled("s", Style::default().fg(Color::Yellow)),
        Span::raw(" Sell  "),
        Span::styled("d", Style::default().fg(Color::Yellow)),
        Span::raw(" Dividend  "),
        Span::styled("r", Style::default().fg(Color::Yellow)),
        Span::raw(" Refresh  "),
        Span::styled("/", Style::default().fg(Color::Yellow)),
        Span::raw(" Search"),
    ];

    let mut footer_content = vec![Line::from(footer_spans)];
    if let Some(msg) = &app.message {
        footer_content.push(Line::from(Span::styled(msg.clone(), Style::default().fg(Color::Magenta))));
    }

    let footer = Paragraph::new(footer_content)
        .block(Block::default().borders(Borders::ALL));
    f.render_widget(footer, chunks[2]);

    // Search overlay
    if app.input_mode == InputMode::Search {
        let area = centered_rect(50, 3, size);
        f.render_widget(Clear, area);
        let search_box = Paragraph::new(format!("/{}", app.search_input))
            .block(Block::default().borders(Borders::ALL).title("Search").border_style(Style::default().fg(Color::Yellow)));
        f.render_widget(search_box, area);
    }
}

fn centered_rect(percent_x: u16, height: u16, r: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length((r.height.saturating_sub(height)) / 2),
            Constraint::Length(height),
            Constraint::Min(0),
        ])
        .split(r);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(popup_layout[1])[1]
}
