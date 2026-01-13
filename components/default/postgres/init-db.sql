-- Create a test database
CREATE DATABASE test_db;

-- Connect to the new database
\c test_db

-- Create a users table
CREATE TABLE users (
    user_id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    first_name VARCHAR(50),
    last_name VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_active BOOLEAN DEFAULT true
);

-- Create a products table
CREATE TABLE products (
    product_id SERIAL PRIMARY KEY,
    product_name VARCHAR(100) NOT NULL,
    description TEXT,
    price DECIMAL(10, 2) NOT NULL,
    stock_quantity INTEGER DEFAULT 0,
    category VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create an orders table
CREATE TABLE orders (
    order_id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(user_id),
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    total_amount DECIMAL(10, 2),
    status VARCHAR(20) DEFAULT 'pending'
);

-- Create order_items table (many-to-many relationship)
CREATE TABLE order_items (
    order_item_id SERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES orders(order_id),
    product_id INTEGER REFERENCES products(product_id),
    quantity INTEGER NOT NULL,
    unit_price DECIMAL(10, 2) NOT NULL
);


-- Insert sample users
INSERT INTO users (username, email, first_name, last_name) VALUES
('jdoe', 'john.doe@example.com', 'John', 'Doe'),
('asmith', 'alice.smith@example.com', 'Alice', 'Smith'),
('bjones', 'bob.jones@example.com', 'Bob', 'Jones'),
('cmiller', 'carol.miller@example.com', 'Carol', 'Miller'),
('dwilson', 'david.wilson@example.com', 'David', 'Wilson'),
('ebrown', 'emma.brown@example.com', 'Emma', 'Brown'),
('ftaylor', 'frank.taylor@example.com', 'Frank', 'Taylor'),
('ganderson', 'grace.anderson@example.com', 'Grace', 'Anderson');

-- Insert sample products
INSERT INTO products (product_name, description, price, stock_quantity, category) VALUES
('Laptop', 'High-performance laptop with 16GB RAM', 1299.99, 50, 'Electronics'),
('Wireless Mouse', 'Ergonomic wireless mouse', 29.99, 200, 'Electronics'),
('Office Chair', 'Comfortable ergonomic office chair', 249.99, 30, 'Furniture'),
('Desk Lamp', 'LED desk lamp with adjustable brightness', 45.99, 100, 'Furniture'),
('USB-C Cable', '2m USB-C charging cable', 12.99, 500, 'Accessories'),
('Bluetooth Headphones', 'Noise-canceling wireless headphones', 199.99, 75, 'Electronics'),
('Standing Desk', 'Adjustable height standing desk', 599.99, 20, 'Furniture'),
('Webcam', '1080p HD webcam', 89.99, 60, 'Electronics'),
('Notebook', 'Professional notebook, 200 pages', 8.99, 300, 'Stationery'),
('Water Bottle', 'Insulated stainless steel water bottle', 24.99, 150, 'Accessories');

-- Insert sample orders
INSERT INTO orders (user_id, total_amount, status) VALUES
(1, 1329.98, 'completed'),
(2, 279.98, 'completed'),
(3, 1899.97, 'pending'),
(4, 45.99, 'completed'),
(5, 824.97, 'shipped'),
(1, 199.99, 'completed'),
(3, 12.99, 'pending'),
(6, 649.98, 'completed');

-- Insert order items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
-- Order 1 (jdoe)
(1, 1, 1, 1299.99),
(1, 2, 1, 29.99),
-- Order 2 (asmith)
(2, 3, 1, 249.99),
(2, 2, 1, 29.99),
-- Order 3 (bjones)
(3, 1, 1, 1299.99),
(3, 7, 1, 599.99),
-- Order 4 (cmiller)
(4, 4, 1, 45.99),
-- Order 5 (dwilson)
(5, 6, 1, 199.99),
(5, 7, 1, 599.99),
(5, 5, 2, 12.99),
-- Order 6 (jdoe second order)
(6, 6, 1, 199.99),
-- Order 7 (bjones second order)
(7, 5, 1, 12.99),
-- Order 8 (ebrown)
(8, 7, 1, 599.99),
(8, 8, 1, 89.99);

-- Count records in each table
SELECT 'users' AS table_name, COUNT(*) AS count FROM users
UNION ALL
SELECT 'products', COUNT(*) FROM products
UNION ALL
SELECT 'orders', COUNT(*) FROM orders
UNION ALL
SELECT 'order_items', COUNT(*) FROM order_items;

-- View all users
SELECT * FROM users;

-- View all products
SELECT * FROM products ORDER BY category, product_name;

-- View orders with user details
SELECT
    o.order_id,
    u.username,
    u.email,
    o.order_date,
    o.total_amount,
    o.status
FROM orders o
JOIN users u ON o.user_id = u.user_id
ORDER BY o.order_date DESC;

-- View order details with products
SELECT
    o.order_id,
    u.username,
    p.product_name,
    oi.quantity,
    oi.unit_price,
    (oi.quantity * oi.unit_price) AS line_total
FROM orders o
JOIN users u ON o.user_id = u.user_id
JOIN order_items oi ON o.order_id = oi.order_id
JOIN products p ON oi.product_id = p.product_id
ORDER BY o.order_id;

-- Get total sales by category
SELECT
    p.category,
    COUNT(DISTINCT o.order_id) AS num_orders,
    SUM(oi.quantity) AS total_items_sold,
    SUM(oi.quantity * oi.unit_price) AS total_revenue
FROM products p
JOIN order_items oi ON p.product_id = oi.product_id
JOIN orders o ON oi.order_id = o.order_id
GROUP BY p.category
ORDER BY total_revenue DESC;

-- Get top customers by spending
SELECT
    u.username,
    u.email,
    COUNT(o.order_id) AS num_orders,
    SUM(o.total_amount) AS total_spent
FROM users u
JOIN orders o ON u.user_id = o.user_id
GROUP BY u.user_id, u.username, u.email
ORDER BY total_spent DESC;
