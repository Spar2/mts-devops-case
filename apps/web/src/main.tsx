import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { MotionConfig } from "motion/react";
import { AppTheme } from "./theme";
import Landing from "./landing";
import { Login } from "./login";
import { ServiceDesk } from "./service";
import "./app.scss";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AppTheme>
      <MotionConfig reducedMotion="user">
        <BrowserRouter>
          <Routes>
            <Route path="/" element={<Landing />} />
            <Route path="/login" element={<Login />} />
            <Route path="/service" element={<ServiceDesk />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </BrowserRouter>
      </MotionConfig>
    </AppTheme>
  </StrictMode>,
);
