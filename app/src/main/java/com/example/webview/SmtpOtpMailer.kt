package com.example.webview

import android.util.Base64
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

data class SmtpSendResult(val success: Boolean, val errorMessage: String? = null)

object SmtpOtpMailer {
  private const val CONNECT_TIMEOUT_MS = 15_000
  private const val READ_TIMEOUT_MS = 15_000

  fun sendOtpEmail(
    host: String,
    port: Int,
    senderEmail: String,
    senderName: String,
    smtpPassword: String,
    toEmail: String,
    recipientName: String,
    otpCode: String,
  ): SmtpSendResult {
    val cleanHost = sanitizeHeader(host).ifEmpty { "smtp.gmail.com" }
    val cleanPort = if (port in 1..65535) port else 465
    val cleanSender = sanitizeHeader(senderEmail)
    val cleanSenderName = sanitizeHeader(senderName).ifEmpty { "Play2Win" }
    val cleanTo = sanitizeHeader(toEmail)
    val cleanToName = sanitizeHeader(recipientName).ifEmpty { cleanTo.substringBefore('@') }
    val cleanOtp = sanitizeHeader(otpCode)
    val cleanPassword =
      if (
        cleanHost.contains("gmail", ignoreCase = true) &&
          smtpPassword.replace(" ", "").length == 16
      ) {
        smtpPassword.replace(" ", "")
      } else {
        smtpPassword
      }

    if (cleanSender.isEmpty() || cleanPassword.isEmpty()) {
      return SmtpSendResult(false, "SMTP sender email or password is missing in database.")
    }
    if (cleanTo.isEmpty() || !cleanOtp.matches(Regex("^\\d{6}$"))) {
      return SmtpSendResult(false, "Invalid recipient email or 6-digit OTP code.")
    }

    var socket: Socket? = null
    return try {
      socket =
        if (cleanPort == 465) {
          val ssl = SSLSocketFactory.getDefault().createSocket() as SSLSocket
          ssl.connect(InetSocketAddress(cleanHost, cleanPort), CONNECT_TIMEOUT_MS)
          ssl.soTimeout = READ_TIMEOUT_MS
          ssl.startHandshake()
          ssl
        } else {
          Socket().apply {
            connect(InetSocketAddress(cleanHost, cleanPort), CONNECT_TIMEOUT_MS)
            soTimeout = READ_TIMEOUT_MS
          }
        }

      var reader = BufferedReader(InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8))
      var writer = BufferedWriter(OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8))

      readExpected(reader, 220)
      sendCommand(writer, "EHLO localhost")
      readExpected(reader, 250)

      if (cleanPort != 465) {
        sendCommand(writer, "STARTTLS")
        readExpected(reader, 220)
        val upgraded =
          (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(
            socket,
            cleanHost,
            cleanPort,
            true,
          ) as SSLSocket
        upgraded.soTimeout = READ_TIMEOUT_MS
        upgraded.startHandshake()
        socket = upgraded
        reader = BufferedReader(InputStreamReader(upgraded.getInputStream(), StandardCharsets.UTF_8))
        writer = BufferedWriter(OutputStreamWriter(upgraded.getOutputStream(), StandardCharsets.UTF_8))
        sendCommand(writer, "EHLO localhost")
        readExpected(reader, 250)
      }

      sendCommand(writer, "AUTH LOGIN")
      readExpected(reader, 334)

      sendCommand(writer, toBase64(cleanSender))
      readExpected(reader, 334)

      sendCommand(writer, toBase64(cleanPassword))
      val authResp = readSmtpResponse(reader)
      if (authResp.first != 235) {
        val raw = authResp.second
        val msg =
          if (authResp.first == 535 || raw.contains("Username and Password", ignoreCase = true) || raw.contains("Application-specific", ignoreCase = true)) {
            "Gmail SMTP authentication failed for $cleanSender. Make sure 2-Step Verification and a 16-digit Gmail App Password are set in email_smtp_settings."
          } else {
            "SMTP login error (${authResp.first}): $raw"
          }
        return SmtpSendResult(false, msg)
      }

      sendCommand(writer, "MAIL FROM:<$cleanSender>")
      readExpected(reader, 250)

      sendCommand(writer, "RCPT TO:<$cleanTo>")
      readExpected(reader, 250)

      sendCommand(writer, "DATA")
      readExpected(reader, 354)

      val rfcMessage =
        dotStuffSmtpData(
          buildOtpEmailMessage(
            senderEmail = cleanSender,
            senderName = cleanSenderName,
            toEmail = cleanTo,
            recipientName = cleanToName,
            otpCode = cleanOtp,
          )
        )
      writer.write(rfcMessage)
      writer.write("\r\n.\r\n")
      writer.flush()
      readExpected(reader, 250)

      runCatching {
        sendCommand(writer, "QUIT")
        readSmtpResponse(reader)
      }

      SmtpSendResult(true, null)
    } catch (e: Exception) {
      val detail = e.message?.trim().orEmpty().ifEmpty { e.javaClass.simpleName }
      SmtpSendResult(false, "Could not send OTP email: $detail")
    } finally {
      runCatching { socket?.close() }
    }
  }

  internal fun buildOtpEmailMessage(
    senderEmail: String,
    senderName: String,
    toEmail: String,
    recipientName: String,
    otpCode: String,
  ): String {
    val senderDomain = senderEmail.substringAfter('@', "gmail.com").ifBlank { "gmail.com" }
    val dateFormat =
      SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss Z", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
      }
    val dateHeader = dateFormat.format(Date())
    val messageId = "<${UUID.randomUUID()}@$senderDomain>"
    val boundary = "p2w_alt_${UUID.randomUUID().toString().replace("-", "").take(16)}"
    val safeName = recipientName.ifBlank { toEmail.substringBefore('@') }

    val plainBody =
      """
      Hi $safeName,

      Your $senderName verification code is: $otpCode

      Enter this 6-digit code in the $senderName app to complete your email verification. This code is valid for 10 minutes.

      If you did not try to register on $senderName, you can safely ignore this message.

      Regards,
      $senderName Support
      """
        .trimIndent()
        .replace("\n", "\r\n")

    val htmlBody =
      """
      <!DOCTYPE html>
      <html>
      <head><meta charset="UTF-8" /></head>
      <body style="margin:0;padding:24px;background:#f4f6f9;font-family:Arial,Helvetica,sans-serif;color:#1e293b;">
        <div style="max-width:480px;margin:0 auto;background:#ffffff;border:1px solid #e2e8f0;border-radius:12px;padding:28px;">
          <h2 style="margin:0 0 12px;color:#0f172a;font-size:20px;font-weight:700;">${escapeHtml(senderName)} Email Verification</h2>
          <p style="margin:0 0 16px;color:#334155;font-size:14px;line-height:1.6;">
            Hi ${escapeHtml(safeName)},
          </p>
          <p style="margin:0 0 18px;color:#334155;font-size:14px;line-height:1.6;">
            Use the 6-digit verification code below to verify your email address and create your account:
          </p>
          <div style="margin:20px 0;padding:16px;border-radius:8px;background:#f1f5f9;border:1px solid #cbd5e1;text-align:center;">
            <span style="font-size:28px;font-weight:700;letter-spacing:6px;color:#0f172a;">$otpCode</span>
          </div>
          <p style="margin:0 0 12px;color:#475569;font-size:13px;line-height:1.5;">
            This verification code is valid for 10 minutes. Do not share it with anyone.
          </p>
          <p style="margin:0;color:#64748b;font-size:12px;line-height:1.5;">
            If you did not request this code, please ignore this email.
          </p>
        </div>
      </body>
      </html>
      """
        .trimIndent()
        .replace("\n", "\r\n")

    return buildString {
      append("From: $senderName <$senderEmail>\r\n")
      append("Reply-To: $senderEmail\r\n")
      append("To: <$toEmail>\r\n")
      append("Subject: $senderName verification code: $otpCode\r\n")
      append("Date: $dateHeader\r\n")
      append("Message-ID: $messageId\r\n")
      append("MIME-Version: 1.0\r\n")
      append("Content-Type: multipart/alternative; boundary=\"$boundary\"\r\n")
      append("\r\n")
      append("--$boundary\r\n")
      append("Content-Type: text/plain; charset=UTF-8\r\n")
      append("Content-Transfer-Encoding: 8bit\r\n")
      append("\r\n")
      append(plainBody)
      append("\r\n\r\n")
      append("--$boundary\r\n")
      append("Content-Type: text/html; charset=UTF-8\r\n")
      append("Content-Transfer-Encoding: 8bit\r\n")
      append("\r\n")
      append(htmlBody)
      append("\r\n\r\n")
      append("--$boundary--\r\n")
    }
  }

  private fun dotStuffSmtpData(raw: String): String =
    raw.split("\r\n").joinToString("\r\n") { line -> if (line.startsWith(".")) ".$line" else line }

  private fun sanitizeHeader(value: String?): String =
    value.orEmpty().replace("\r", "").replace("\n", "").trim()

  private fun escapeHtml(text: String): String =
    text
      .replace("&", "&amp;")
      .replace("<", "&lt;")
      .replace(">", "&gt;")
      .replace("\"", "&quot;")

  private fun toBase64(text: String): String =
    Base64.encodeToString(text.toByteArray(StandardCharsets.UTF_8), Base64.NO_WRAP)

  private fun sendCommand(writer: BufferedWriter, cmd: String) {
    writer.write(cmd)
    writer.write("\r\n")
    writer.flush()
  }

  private fun readExpected(reader: BufferedReader, expectedCode: Int): String {
    val (code, message) = readSmtpResponse(reader)
    if (code != expectedCode) {
      throw IllegalStateException("SMTP $expectedCode expected, got $code: $message")
    }
    return message
  }

  private fun readSmtpResponse(reader: BufferedReader): Pair<Int, String> {
    val lines = StringBuilder()
    var lastCode = -1
    while (true) {
      val line = reader.readLine() ?: throw IllegalStateException("Unexpected end of SMTP stream")
      if (lines.isNotEmpty()) lines.append(' ')
      lines.append(line)
      if (line.length >= 3 && line[0].isDigit() && line[1].isDigit() && line[2].isDigit()) {
        lastCode = line.substring(0, 3).toInt()
        if (line.length == 3 || line[3] == ' ') {
          break
        }
      } else {
        break
      }
    }
    return lastCode to lines.toString()
  }
}
