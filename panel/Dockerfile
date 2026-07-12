FROM node:20-slim

# Install build deps for better-sqlite3 native module + sudo + docker CLI
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ \
    sudo docker.io \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install ALL deps (devDeps needed for tailwindcss/postcss at build time)
COPY package.json package-lock.json* ./
RUN npm install

# Copy app
COPY . .

# Build Next.js (needs tailwindcss, postcss, autoprefixer from devDeps)
RUN npm run build

# Prune devDependencies to slim the production image
RUN npm prune --omit=dev

# Data directory for SQLite (mounted as volume at runtime)
RUN mkdir -p /app/data

EXPOSE 3000

CMD ["npm", "start"]
